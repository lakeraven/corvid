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

    class PatientMismatchError < StandardError; end

    def initialize(target:)
      @target = target
    end

    def run(case_record:, consent:, bundle:)
      ensure_patient_match!(case_record, bundle)

      decision = Corvid::Migration::TribalConsentGate.new.evaluate(case_record: case_record, consent: consent)
      unless decision.granted?
        determination = record_audit(case_record, outcome: "denied", reason: decision.reason, actor: consent&.actor_identifier)
        return Result.new(migrated: false, determination: determination, reason: decision.reason)
      end

      filtered = Corvid::Migration::MinimumNecessary.filter(bundle, decision.consented_types)
      if filtered.entries.empty?
        return Result.new(migrated: false, reason: "Nothing to migrate: no source entries matched the consented types")
      end

      determination = record_audit(case_record, outcome: "approved",
                                   reason: "Migration authorized by Data Governance Board",
                                   actor: consent.actor_identifier)

      response = @target.reconcile!(patient_ref: case_record.patient_identifier, bundle: filtered)

      if relay_succeeded?(response, filtered)
        Result.new(migrated: true, determination: determination, target_response: response, bundle: filtered)
      else
        Result.new(migrated: false, determination: determination, target_response: response, bundle: filtered,
                   reason: "Migration relay did not complete successfully")
      end
    end

    private

    # Cross-patient guard: the bundle's patient_ref must match the case's
    # patient. Prevents consent for patient A from relaying patient B's data.
    def ensure_patient_match!(case_record, bundle)
      return if bundle.patient_ref.to_s == case_record.patient_identifier.to_s

      raise PatientMismatchError, "bundle patient_ref does not match the case patient"
    end

    # staff_review requires determined_by_identifier; fall back to automated
    # when no actor is present so a missing actor never crashes the audit.
    def record_audit(case_record, outcome:, reason:, actor:)
      method = actor.to_s.strip.empty? ? "automated" : "staff_review"
      case_record.record_determination!(outcome: outcome, decision_method: method,
                                        reasons: [ reason ], determined_by_identifier: actor.presence)
    end

    def relay_succeeded?(response, filtered)
      return false unless response.is_a?(Hash)
      return false unless response[:success] == true || response["success"] == true

      posted = response[:posted] || response["posted"]
      posted.nil? || posted.to_i == filtered.entries.size
    end
  end
end
