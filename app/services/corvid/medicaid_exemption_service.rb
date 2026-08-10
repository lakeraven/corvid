# frozen_string_literal: true

require "digest"
require "json"

module Corvid
  # Asserts an AI/AN Medicaid exemption on the member record from a VERIFIED
  # status (never self-report), and records exemption life-outcome events.
  #
  # Under HR-1 (2025) AI/AN — including Urban Indians and IHS beneficiaries —
  # are exempt from Medicaid work requirements and 6-month redeterminations
  # (effective Jan 2027). assert verifies the status through the adapter
  # (backed by baseroll IAL2/AAL2 verification) and, only when the source
  # confirms it, writes/refreshes MedicaidExemption rows plus an :asserted
  # ExemptionEvent — all in one transaction.
  #
  # Fail-closed: if the verification source is unavailable, or the person is
  # not AI/AN, NO exemption is written. There is no silent fallback and no
  # fabricated positive.
  #
  # Result reasons (stable enum strings):
  #   :asserted                 — exemption(s) written/refreshed
  #   :verification_unavailable — source unreachable; nothing asserted
  #   :not_ai_an                — source says person is not AI/AN; nothing asserted
  module MedicaidExemptionService
    DEFAULT_BASIS = "ai_an_ihs_beneficiary"

    AssertionResult = Struct.new(
      :asserted,
      :reason,
      :exemption_ids,
      :provider_source,
      :provider_confidence,
      keyword_init: true
    ) do
      alias_method :asserted?, :asserted
    end

    class << self
      # Assert the HR-1 exemptions for a person from verified AI/AN status.
      #
      # exemption_types defaults to both HR-1 categories. as_of_date is the
      # verification-as-of date; effective_date is when the exemption takes
      # effect (defaults to as_of_date). asserted_by_identifier is the actor
      # (a host user identifier); nil for fully-automated runs.
      def assert(person_identifier:,
                 facility_identifier: nil,
                 exemption_types: MedicaidExemption::EXEMPTION_TYPES,
                 as_of_date: Date.current,
                 effective_date: nil,
                 expires_at: nil,
                 asserted_by_identifier: nil,
                 tenant_identifier: nil)
        tenant_identifier ||= Corvid::TenantContext.current_tenant_identifier
        effective_date ||= as_of_date

        status = Corvid.adapter.verify_ai_an_status(person_identifier)

        if status[:confidence] == :unavailable
          return AssertionResult.new(
            asserted: false, reason: :verification_unavailable, exemption_ids: [],
            provider_source: provider_source_for(Corvid.adapter),
            provider_confidence: status[:confidence].to_s
          )
        end

        unless status[:ai_an] || status[:ihs_beneficiary]
          return AssertionResult.new(
            asserted: false, reason: :not_ai_an, exemption_ids: [],
            provider_source: provider_source_for(Corvid.adapter),
            provider_confidence: status[:confidence].to_s
          )
        end

        snapshot_hash = snapshot_hash_for(status)
        provider_source = provider_source_for(Corvid.adapter)
        basis = status[:basis] || DEFAULT_BASIS
        exemption_ids = []

        ActiveRecord::Base.transaction do
          Array(exemption_types).map(&:to_s).uniq.each do |type|
            exemption = MedicaidExemption.status_asserted.find_or_initialize_by(
              tenant_identifier: tenant_identifier,
              person_identifier: person_identifier,
              exemption_type: type
            )
            exemption.assign_attributes(
              facility_identifier: facility_identifier,
              status: "asserted",
              basis: basis,
              as_of_date: as_of_date,
              effective_date: effective_date,
              expires_at: expires_at,
              verified_at: status[:verified_at] || Time.current,
              verification_source: provider_source,
              verification_confidence: status[:confidence]&.to_s,
              verification_snapshot_hash: snapshot_hash,
              asserted_by_identifier: asserted_by_identifier
            )
            exemption.save!
            exemption_ids << exemption.id

            ExemptionEvent.create!(
              tenant_identifier: tenant_identifier,
              person_identifier: person_identifier,
              medicaid_exemption: exemption,
              exemption_type: type,
              event_type: "asserted",
              occurred_on: as_of_date,
              recorded_by_identifier: asserted_by_identifier
            )
          end
        end

        AssertionResult.new(
          asserted: true, reason: :asserted, exemption_ids: exemption_ids,
          provider_source: provider_source,
          provider_confidence: status[:confidence]&.to_s
        )
      end

      # Record a life-outcome event on a person's exemption (coverage
      # retained, erroneously disenrolled, appeal filed, etc.). Optionally
      # linked to a specific MedicaidExemption.
      def record_outcome(person_identifier:,
                         event_type:,
                         occurred_on: Date.current,
                         exemption: nil,
                         exemption_type: nil,
                         recorded_by_identifier: nil,
                         notes_token: nil,
                         tenant_identifier: nil)
        tenant_identifier ||= Corvid::TenantContext.current_tenant_identifier

        ExemptionEvent.create!(
          tenant_identifier: tenant_identifier,
          person_identifier: person_identifier,
          medicaid_exemption: exemption,
          exemption_type: exemption_type || exemption&.exemption_type,
          event_type: event_type.to_s,
          occurred_on: occurred_on,
          recorded_by_identifier: recorded_by_identifier,
          notes_token: notes_token
        )
      end

      private

      # Hash the STABLE verified status (excludes verified_at) so an identical
      # verified status produces an identical hash — auditors can confirm a
      # re-verify used the same upstream data.
      def snapshot_hash_for(status)
        Digest::SHA256.hexdigest(
          JSON.generate(
            ai_an: status[:ai_an],
            ihs_beneficiary: status[:ihs_beneficiary],
            basis: status[:basis],
            confidence: status[:confidence]
          )
        )
      end

      def provider_source_for(adapter)
        adapter.class.name
      end
    end
  end
end
