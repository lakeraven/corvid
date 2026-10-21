# frozen_string_literal: true

module Corvid
  # Composes the adapter's enrollment, identity, and residency primitives
  # into a PRC-eligibility decision, applies site-configurable rules, and
  # persists the decision as a PrcEligibilityDecision row in a single
  # database transaction.
  #
  # The verification snapshot stored on the row is an HMAC-SHA256 under the
  # host's current key (ADR 0008). With no usable key, the hash and key
  # version are left nil and the decision is still saved.
  #
  # Reason codes (stable enum strings) returned in EligibilityDecision and
  # persisted on PrcEligibilityDecision.reason_codes:
  #
  #   :provider_unavailable_fail_closed  — confidence is not :verified or :stale
  #   :not_enrolled                      — adapter says not enrolled
  #   :not_enrolled_in_contracted_tribe  — enrolled, but tribe_code is blank or not the contracted tribe
  #   :off_reservation                   — facility requires on-reservation and adapter says off-reservation
  #   :ssn_missing                       — facility requires SSN-on-file and adapter says ssn_present: false
  #   :enrollment_stale                  — informational warning when source flagged data as stale
  #
  # Eligibility rule: deny if ANY hard-fail reason present; otherwise
  # approve (stale confidence is non-blocking — surfaces as a warning).
  module TribalEligibilityService
    HARD_FAIL_REASONS = %i[
      provider_unavailable_fail_closed
      not_enrolled
      not_enrolled_in_contracted_tribe
      off_reservation
      ssn_missing
    ].freeze

    EligibilityDecision = Struct.new(
      :eligible,
      :reason_codes,
      :provider_source,
      :provider_confidence,
      :decision_id,
      keyword_init: true
    ) do
      alias_method :eligible?, :eligible
    end

    class << self
      # facility is any object responding to:
      #   - identifier
      #   - contracted_tribe_code
      #   - requires_on_reservation? (boolean)
      #   - requires_ssn_on_file? (boolean)
      #
      # decided_by_identifier identifies the actor (a user identifier from
      # the host application). May be nil for fully-automated runs.
      def decide(person_identifier:, facility:, as_of_date: Date.current, decided_by_identifier: nil, tenant_identifier: nil)
        tenant_identifier = tenant_identifier.presence || Corvid::TenantContext.current_tenant_identifier

        enrollment = Corvid.adapter.verify_tribal_enrollment(person_identifier)
        identity   = Corvid.adapter.verify_identity_documents(person_identifier)
        residency  = Corvid.adapter.verify_residency(person_identifier)

        reasons = []
        reasons.concat(enrollment_reasons(enrollment, facility))
        reasons.concat(identity_reasons(identity, facility))
        reasons.concat(residency_reasons(residency, facility))

        eligible = (reasons & HARD_FAIL_REASONS).empty?

        snapshot_hash, snapshot_key_version = SnapshotFingerprint.compute(
          { enrollment: enrollment, identity: identity, residency: residency }
        )

        decision_row = PrcEligibilityDecision.new(
          tenant_identifier: tenant_identifier,
          person_identifier: person_identifier,
          facility_identifier: facility.identifier,
          decided_by_identifier: decided_by_identifier,
          decided_at: Time.current,
          as_of_date: as_of_date,
          eligible: eligible,
          reason_codes: reasons.map(&:to_s),
          provider_source: provider_source_for(Corvid.adapter),
          provider_confidence: enrollment[:confidence]&.to_s,
          verification_snapshot_hash: snapshot_hash,
          verification_snapshot_key_version: snapshot_key_version
        )

        ActiveRecord::Base.transaction do
          decision_row.save!
        end

        EligibilityDecision.new(
          eligible: eligible,
          reason_codes: reasons,
          provider_source: decision_row.provider_source,
          provider_confidence: decision_row.provider_confidence,
          decision_id: decision_row.id
        )
      end

      private

      def enrollment_reasons(enrollment, facility)
        confidence = enrollment[:confidence]
        # Fail closed on anything other than the two usable symbols.
        return [ :provider_unavailable_fail_closed ] unless %i[verified stale].include?(confidence)

        reasons = []
        unless enrollment[:enrolled]
          reasons << :not_enrolled
          return reasons
        end

        contracted = facility.contracted_tribe_code
        tribe_code = enrollment[:tribe_code]
        # Nil or blank tribe_code cannot satisfy a contracted tribe.
        if contracted && (tribe_code.blank? || tribe_code != contracted)
          reasons << :not_enrolled_in_contracted_tribe
        end

        reasons << :enrollment_stale if confidence == :stale
        reasons
      end

      def identity_reasons(identity, facility)
        return [] unless facility.respond_to?(:requires_ssn_on_file?) && facility.requires_ssn_on_file?
        return [] if identity[:ssn_present]

        [ :ssn_missing ]
      end

      def residency_reasons(residency, facility)
        return [] unless facility.respond_to?(:requires_on_reservation?) && facility.requires_on_reservation?
        return [] if residency[:on_reservation]

        [ :off_reservation ]
      end

      def provider_source_for(adapter)
        adapter.class.name
      end
    end
  end
end
