# frozen_string_literal: true

module Corvid
  # Builds the at-risk worklist: exempt members whom the state has nonetheless
  # flagged for a work-reporting requirement or a 6-month redetermination they
  # are exempt from. These are the members at risk of losing coverage to
  # administrative churn — surfaced here for proactive correction/outreach
  # (pairs with the renewal-tracking worklist, #410).
  #
  # State-side signals are supplied by the caller. Their persistence and
  # ingestion (from 271 responses, renewal files, or case data) is the
  # province of the renewal-tracking feature (#410); this service stays
  # PG-only and takes the signals as input so it can be exercised today.
  #
  # A signal is any object or hash carrying:
  #   person_identifier   — opaque member token
  #   requirement_type    — one of MedicaidExemption::EXEMPTION_TYPES
  #   source              — where the flag came from (e.g. "state_271", string)
  #   flagged_on          — date the state imposed the requirement (optional)
  module ExemptionWorklistService
    AtRiskEntry = Struct.new(
      :person_identifier,
      :requirement_type,
      :exemption_id,
      :exemption_type,
      :source,
      :flagged_on,
      keyword_init: true
    )

    class << self
      # Returns an array of AtRiskEntry for signals whose person has an
      # in-effect exemption matching the flagged requirement. Signals with no
      # matching verified exemption are NOT at-risk here (they are not exempt
      # members, so they belong to the general renewal worklist, #410).
      def at_risk(state_signals, as_of: Time.current, tenant_identifier: nil)
        tenant_identifier ||= Corvid::TenantContext.current_tenant_identifier

        Array(state_signals).filter_map do |raw|
          signal = normalize(raw)
          next unless signal[:person_identifier] && signal[:requirement_type]

          exemption = MedicaidExemption
            .where(tenant_identifier: tenant_identifier)
            .for_person(signal[:person_identifier])
            .of_type(signal[:requirement_type])
            .active
            .detect { |e| e.in_effect?(as_of: as_of) }
          next unless exemption

          AtRiskEntry.new(
            person_identifier: signal[:person_identifier],
            requirement_type: signal[:requirement_type],
            exemption_id: exemption.id,
            exemption_type: exemption.exemption_type,
            source: signal[:source],
            flagged_on: signal[:flagged_on]
          )
        end
      end

      private

      def normalize(raw)
        if raw.is_a?(Hash)
          {
            person_identifier: (raw[:person_identifier] || raw["person_identifier"]),
            requirement_type: (raw[:requirement_type] || raw["requirement_type"])&.to_s,
            source: (raw[:source] || raw["source"]),
            flagged_on: (raw[:flagged_on] || raw["flagged_on"])
          }
        else
          {
            person_identifier: raw.person_identifier,
            requirement_type: raw.requirement_type&.to_s,
            source: (raw.respond_to?(:source) ? raw.source : nil),
            flagged_on: (raw.respond_to?(:flagged_on) ? raw.flagged_on : nil)
          }
        end
      end
    end
  end
end
