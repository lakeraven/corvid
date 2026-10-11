# frozen_string_literal: true

require "digest"
require "json"

module Corvid
  # Establishes whether a person qualifies for the H.R. 1 Medicaid
  # community-engagement exemption for American Indians and Alaska Natives,
  # and on what evidence. See ADR 0007.
  #
  # Evidence comes from one or more sources, checked in order. Each source is
  # any object implementing some subset of the AI/AN evidence methods on
  # Corvid::Adapters::Base: a state claims feed, a tribal enrollment office,
  # a clinic EHR adapter. Methods a source does not implement are skipped.
  #
  # Bases (stable enum strings, persisted on AianExemptionDetermination#bases):
  #
  #   :enrolled_tribal_member                 — enrolled in a federally recognized tribe
  #   :descendant_of_enrolled_member          — child or grandchild of an enrolled member
  #   :alaska_native_corporation_shareholder  — shareholder in an Alaska Native Corporation
  #   :received_itu_services                  — received care at an IHS, tribal or urban Indian site
  #
  # Outcomes:
  #
  #   :exempt          — at least one basis established
  #   :not_established — sources answered, none established a basis. NOT a
  #                      finding that the person is not AI/AN; the caller
  #                      falls back to attestation or documents.
  #   :unavailable     — no source could be reached; retry later.
  class AianExemptionService
    BASES = %i[
      enrolled_tribal_member
      descendant_of_enrolled_member
      alaska_native_corporation_shareholder
      received_itu_services
    ].freeze

    STATUSES = %i[exempt not_established unavailable].freeze

    # Adapter method that answers each basis.
    CHECKS = {
      enrolled_tribal_member: :verify_tribal_enrollment,
      descendant_of_enrolled_member: :verify_tribal_descent,
      alaska_native_corporation_shareholder: :verify_alaska_native_corporation_shareholder,
      received_itu_services: :list_itu_encounters
    }.freeze

    Determination = Struct.new(:status, :bases, :warnings, :determination_id, keyword_init: true) do
      def exempt?
        status == :exempt
      end
    end

    class << self
      def determine(sources: [ Corvid.adapter ], **kwargs)
        new(sources: sources).determine(**kwargs)
      end
    end

    def initialize(sources: [ Corvid.adapter ])
      @sources = Array(sources)
    end

    # itu_lookback_days is a state policy choice: how recent an I/T/U service
    # must be to count. nil means any service on or before as_of_date.
    def determine(person_identifier:, as_of_date: Date.current, itu_lookback_days: nil,
                  decided_by_identifier: nil, tenant_identifier: nil)
      tenant_identifier ||= Corvid::TenantContext.current_tenant_identifier
      since = itu_lookback_days && (as_of_date - itu_lookback_days)

      evidence = []
      raw = []
      answered = false

      @sources.each do |source|
        CHECKS.each do |basis, check|
          response = call_check(source, check, person_identifier, since)
          next if response.nil?

          raw << { source: source_name(source), basis: basis, response: response }
          next if response[:confidence] == :unavailable

          answered = true
          next unless established?(basis, response, as_of_date, since)

          evidence << { basis: basis, source: source_name(source), confidence: response[:confidence] || :verified }
        end
      end

      bases = BASES & evidence.map { |e| e[:basis] }
      status = if bases.any? then :exempt
      elsif answered then :not_established
      else :unavailable
      end
      warnings = evidence.any? { |e| e[:confidence] == :stale } ? [ :evidence_stale ] : []

      row = AianExemptionDetermination.create!(
        tenant_identifier: tenant_identifier,
        person_identifier: person_identifier,
        decided_by_identifier: decided_by_identifier,
        decided_at: Time.current,
        as_of_date: as_of_date,
        status: status.to_s,
        bases: bases.map(&:to_s),
        warnings: warnings.map(&:to_s),
        evidence: evidence.map { |e| e.transform_values(&:to_s) },
        verification_snapshot_hash: Digest::SHA256.hexdigest(JSON.generate(raw))
      )

      Determination.new(status: status, bases: bases, warnings: warnings, determination_id: row.id)
    end

    private

    def call_check(source, check, person_identifier, since)
      return nil unless source.respond_to?(check)

      if check == :list_itu_encounters
        source.public_send(check, person_identifier, since: since)
      else
        source.public_send(check, person_identifier)
      end
    rescue NotImplementedError
      nil
    end

    def established?(basis, response, as_of_date, since)
      case basis
      when :enrolled_tribal_member then response[:enrolled] == true
      when :descendant_of_enrolled_member then response[:descendant] == true
      when :alaska_native_corporation_shareholder then response[:shareholder] == true
      when :received_itu_services
        Array(response[:encounters]).any? do |e|
          date = e[:service_date]
          date && date <= as_of_date && (since.nil? || date >= since)
        end
      end
    end

    def source_name(source)
      source.class.name || "anonymous_source"
    end
  end
end
