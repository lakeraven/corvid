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

    # Allow-list of confidence levels a verified response may carry to assert
    # an exemption. Per the adapter contract (Adapters::Base#verify_ai_an_status)
    # :verified is the only level where the source returned current,
    # trustworthy data. :stale is data flagged out-of-date and is NOT accepted:
    # asserting a Medicaid work-requirement exemption off stale AI/AN
    # verification could carry a member on a protection the source no longer
    # stands behind. Everything else (:stale, :unavailable, nil, or any
    # unknown/malformed value) is untrustworthy and asserts nothing.
    ACCEPTED_CONFIDENCE = %i[verified].freeze

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

        types = Array(exemption_types).map(&:to_s).uniq
        if types.empty?
          return AssertionResult.new(
            asserted: false, reason: :no_exemption_types, exemption_ids: []
          )
        end

        status = Corvid.adapter.verify_ai_an_status(person_identifier)
        confidence = status.is_a?(Hash) ? status[:confidence] : nil

        # Verified-only, fail-closed (ALLOW-LIST): assert only from a response
        # whose confidence is an explicitly-accepted level AND that carries a
        # genuine verification timestamp. A nil/unknown confidence, a missing
        # verified_at, or any otherwise-malformed/unavailable response is
        # untrustworthy — treat it as unavailable and assert nothing. There is
        # no fabricated positive and no defaulted verified_at.
        unless verified_response?(status)
          return AssertionResult.new(
            asserted: false, reason: :verification_unavailable, exemption_ids: [],
            provider_source: provider_source_for(Corvid.adapter),
            provider_confidence: confidence&.to_s
          )
        end

        unless status[:ai_an] || status[:ihs_beneficiary]
          return AssertionResult.new(
            asserted: false, reason: :not_ai_an, exemption_ids: [],
            provider_source: provider_source_for(Corvid.adapter),
            provider_confidence: status[:confidence].to_s
          )
        end

        snapshot_hash = snapshot_hash_for(status, person_identifier, tenant_identifier)
        provider_source = provider_source_for(Corvid.adapter)
        basis = status[:basis] || DEFAULT_BASIS
        exemption_ids = []

        ActiveRecord::Base.transaction do
          types.each do |type|
            exemption = upsert_asserted_exemption!(
              tenant_identifier: tenant_identifier,
              person_identifier: person_identifier,
              exemption_type: type,
              attributes: {
                facility_identifier: facility_identifier,
                status: "asserted",
                basis: basis,
                as_of_date: as_of_date,
                effective_date: effective_date,
                expires_at: expires_at,
                verified_at: status[:verified_at],
                verification_source: provider_source,
                verification_confidence: status[:confidence]&.to_s,
                verification_snapshot_hash: snapshot_hash,
                asserted_by_identifier: asserted_by_identifier
              }
            )
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

        # Isolation: a supplied exemption must belong to the same tenant AND
        # the same person the event is being recorded for. Otherwise the event
        # would link one person's/tenant's exemption into another's audit trail.
        if exemption
          if exemption.tenant_identifier != tenant_identifier
            raise ArgumentError, "exemption belongs to a different tenant"
          end
          if exemption.person_identifier != person_identifier
            raise ArgumentError, "exemption belongs to a different person"
          end
        end

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

      # A trustworthy verified response: a Hash whose confidence is on the
      # accepted allow-list (never nil/unknown/unavailable) AND that carries a
      # genuine verification timestamp. Anything else is treated as unavailable
      # so assert fails closed and never fabricates a positive.
      def verified_response?(status)
        status.is_a?(Hash) &&
          ACCEPTED_CONFIDENCE.include?(status[:confidence]) &&
          status[:verified_at].present?
      end

      # Concurrency-safe upsert of the single asserted exemption for
      # (tenant, person, type). Two concurrent asserts can both miss the
      # find_or_initialize_by and then collide on the partial unique index,
      # raising ActiveRecord::RecordNotUnique. Treat that as a benign
      # duplicate: adopt the row the winner committed and refresh it with this
      # run's verified provenance, rather than 500 on the race.
      #
      # The insert runs in a savepoint (requires_new) so a unique violation
      # rolls back only that statement — the surrounding assert transaction
      # (which also writes the :asserted event) stays usable. Fail-closed is
      # preserved: nothing here fabricates a positive; it only reconciles two
      # equally-verified asserts of the same status.
      def upsert_asserted_exemption!(tenant_identifier:, person_identifier:, exemption_type:, attributes:)
        key = {
          tenant_identifier: tenant_identifier,
          person_identifier: person_identifier,
          exemption_type: exemption_type
        }

        exemption = MedicaidExemption.status_asserted.find_or_initialize_by(key)
        exemption.assign_attributes(attributes)

        ActiveRecord::Base.transaction(requires_new: true) { exemption.save! }
        exemption
      rescue ActiveRecord::RecordNotUnique
        existing = MedicaidExemption.status_asserted.find_by!(key)
        existing.update!(attributes)
        existing
      end

      # Hash the STABLE verified status bound to this person and tenant, so the
      # snapshot is unique per subject (not a byte-identical projection shared
      # across everyone with the same flags) and carries the FULL verified
      # payload minus the volatile verified_at. Auditors can confirm a re-verify
      # used the same upstream data for the same person. Mirrors
      # TribalEligibilityService#decide, which hashes the full payloads.
      def snapshot_hash_for(status, person_identifier, tenant_identifier)
        Digest::SHA256.hexdigest(
          JSON.generate(
            tenant_identifier: tenant_identifier,
            person_identifier: person_identifier,
            status: status.except(:verified_at)
          )
        )
      end

      def provider_source_for(adapter)
        adapter.class.name
      end
    end
  end
end
