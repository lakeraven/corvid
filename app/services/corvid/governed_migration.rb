# frozen_string_literal: true

module Corvid
  # Governs a patient-data migration source -> target WITHOUT storing PHI.
  # Enforces Data Governance Board consent BEFORE any data leaves, filters to
  # the consented minimum, records an audit Determination, then relays to the
  # injected target. A consent-denied migration sends NOTHING. (#510 demo subset.)
  #
  # Target contract: any object responding to
  #   reconcile!(patient_ref:, bundle:) -> Hash
  # The transport (e.g. a Lakeraven-EHR FHIR client) lives behind this seam;
  # the governance above is what these tests exercise.
  class GovernedMigration
    Result = Struct.new(:migrated, :determination, :target_response, :bundle, :reason, keyword_init: true) do
      def migrated? = migrated
      def halted? = !migrated
    end

    def initialize(target:)
      @target = target
    end

    def run(case_record:, consent:, bundle:)
      decision = Corvid::Migration::TribalConsentGate.new.evaluate(case_record: case_record, consent: consent)

      unless decision.granted?
        determination = case_record.record_determination!(
          outcome: "denied", decision_method: "staff_review",
          reasons: [decision.reason], determined_by_identifier: consent&.actor_identifier
        )
        return Result.new(migrated: false, determination: determination, reason: decision.reason)
      end

      filtered = Corvid::Migration::MinimumNecessary.filter(bundle, decision.consented_types)

      determination = case_record.record_determination!(
        outcome: "approved", decision_method: "staff_review",
        reasons: ["Migration authorized by Data Governance Board"],
        determined_by_identifier: consent.actor_identifier
      )

      response = @target.reconcile!(patient_ref: case_record.patient_identifier, bundle: filtered)
      Result.new(migrated: true, determination: determination, target_response: response, bundle: filtered)
    end
  end
end
