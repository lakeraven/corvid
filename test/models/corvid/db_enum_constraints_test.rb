# frozen_string_literal: true

require "test_helper"

module Corvid
  # Red-first spec for issue #704: database CHECK / FK constraints on columns
  # that today accept arbitrary strings. Vocabularies are derived from writers
  # (see comments on each constant).
  class DbEnumConstraintsTest < ActiveSupport::TestCase
    TENANT = "tnt_db_enum_constraints"

    # MedicalPriorityService#assign / #assess — app/services/corvid/medical_priority_service.rb:50,59
    PRIORITY_SYSTEM_VALUES = %w[corvid_v1].freeze

    # Corvid::Adapters::Base tribal enrollment confidence — lib/corvid/adapters/base.rb:228-245,310-311
    PROVIDER_CONFIDENCE_VALUES = %w[verified stale unavailable].freeze

    # PrcOverpaymentAnalyzer#analyze — app/services/corvid/prc_overpayment_analyzer.rb:153-371
    PAYMENT_SYSTEM_VALUES = %w[pfs ipps asc opps].freeze

    # PrcOverpaymentAnalyzer (same file) and RecoverableRule::RECOVERABLE_CONFIDENCE —
    # app/services/corvid/recoverable_rule.rb:20
    RECOVERY_CONFIDENCE_VALUES = %w[
      clear stub_estimate no_rate_for_year unmapped_procedure unmapped_facility missing_service_date
    ].freeze

    # FmapClassificationService#missing_evidence — app/services/corvid/fmap_classification_service.rb:240-247
    # FmapRule#unmet_evidence — app/models/corvid/fmap_rule.rb:78-90
    MISSING_EVIDENCE_VOCABULARY = %w[
      evidence_refs aian_attestation received_through_basis aian_status_evidence
      care_coordination_agreement received_through_evidence
    ].freeze

    setup do
      FmapRuleLoader.load_defaults! if defined?(FmapRuleLoader)
    end

    test "Corvid::Case.column_names excludes closure_reason" do
      refute_includes Corvid::Case.column_names, "closure_reason",
                       "closure_reason is unused (no readers/writers) and should be dropped (#704)"
    end

    test "ClaimSubmission.column_names excludes provider_type" do
      refute_includes ClaimSubmission.column_names, "provider_type",
                       "provider_type is unused (no writers) and should be dropped (#704)"
    end

    test "corvid_prc_referrals.priority_system rejects out-of-vocabulary values" do
      with_tenant(TENANT) do
        referral = create_prc_referral!
        assert_db_rejects(referral, priority_system: "legacy_v2")
        assert_db_rejects(referral, priority_system: "not a token")
      end
    end

    test "corvid_prc_referrals.priority_system accepts vocabulary and NULL" do
      with_tenant(TENANT) do
        referral = create_prc_referral!
        PRIORITY_SYSTEM_VALUES.each do |value|
          assert_db_accepts(referral, priority_system: value)
        end
        assert_db_accepts(referral, priority_system: nil)
      end
    end

    test "PrcReferral model rejects out-of-vocabulary priority_system before the database" do
      with_tenant(TENANT) do
        referral = create_prc_referral!
        referral.priority_system = "legacy_v2"
        refute referral.valid?
        assert_includes referral.errors[:priority_system], "is not included in the list"
      end
    end

    test "corvid_prc_eligibility_decisions.provider_confidence rejects out-of-vocabulary values" do
      with_tenant(TENANT) do
        row = create_prc_eligibility_decision!
        assert_db_rejects(row, provider_confidence: "guesswork")
        assert_db_rejects(row, provider_confidence: "verified-ish")
      end
    end

    test "corvid_prc_eligibility_decisions.provider_confidence accepts vocabulary and NULL" do
      with_tenant(TENANT) do
        row = create_prc_eligibility_decision!
        PROVIDER_CONFIDENCE_VALUES.each do |value|
          assert_db_accepts(row, provider_confidence: value)
        end
        assert_db_accepts(row, provider_confidence: nil)
      end
    end

    test "PrcEligibilityDecision model rejects out-of-vocabulary provider_confidence before the database" do
      with_tenant(TENANT) do
        row = create_prc_eligibility_decision!
        row.provider_confidence = "guesswork"
        refute row.valid?
        assert_includes row.errors[:provider_confidence], "is not included in the list"
      end
    end

    test "corvid_prc_overpayment_analyses.payment_system rejects out-of-vocabulary values" do
      with_tenant(TENANT) do
        analysis = create_prc_overpayment_analysis!
        assert_db_rejects(analysis, payment_system: "medicare_part_b")
        assert_db_rejects(analysis, payment_system: "free text")
      end
    end

    test "corvid_prc_overpayment_analyses.payment_system accepts vocabulary and NULL" do
      with_tenant(TENANT) do
        analysis = create_prc_overpayment_analysis!
        PAYMENT_SYSTEM_VALUES.each do |value|
          assert_db_accepts(analysis, payment_system: value)
        end
        assert_db_accepts(analysis, payment_system: nil)
      end
    end

    test "PrcOverpaymentAnalysis model rejects out-of-vocabulary payment_system before the database" do
      with_tenant(TENANT) do
        analysis = create_prc_overpayment_analysis!
        analysis.payment_system = "medicare_part_b"
        refute analysis.valid?
        assert_includes analysis.errors[:payment_system], "is not included in the list"
      end
    end

    test "corvid_prc_overpayment_analyses.recovery_confidence rejects out-of-vocabulary values" do
      with_tenant(TENANT) do
        analysis = create_prc_overpayment_analysis!
        assert_db_rejects(analysis, recovery_confidence: "maybe")
        assert_db_rejects(analysis, recovery_confidence: "CLEAR")
      end
    end

    test "corvid_prc_overpayment_analyses.recovery_confidence accepts vocabulary" do
      with_tenant(TENANT) do
        analysis = create_prc_overpayment_analysis!
        RECOVERY_CONFIDENCE_VALUES.each do |value|
          assert_db_accepts(analysis, recovery_confidence: value)
        end
      end
    end

    test "PrcOverpaymentAnalysis model rejects out-of-vocabulary recovery_confidence before the database" do
      with_tenant(TENANT) do
        analysis = create_prc_overpayment_analysis!
        analysis.recovery_confidence = "maybe"
        refute analysis.valid?
        assert_includes analysis.errors[:recovery_confidence], "is not included in the list"
      end
    end

    test "corvid_fmap_determinations.jurisdiction rejects non two-letter uppercase codes" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        assert_db_rejects(determination, jurisdiction: "usa")
        assert_db_rejects(determination, jurisdiction: "12")
        assert_db_rejects(determination, jurisdiction: "X")
        assert_db_rejects(determination, jurisdiction: "NYC")
        assert_db_rejects(determination, jurisdiction: "ny")
      end
    end

    test "corvid_fmap_determinations.jurisdiction accepts US and state codes used in tests" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        %w[US XA NY].each do |code|
          assert_db_accepts(determination, jurisdiction: code)
        end
      end
    end

    test "FmapDetermination model rejects invalid jurisdiction format before the database" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        determination.jurisdiction = "NYC"
        refute determination.valid?
        assert determination.errors[:jurisdiction].present?
      end
    end

    test "corvid_fmap_determinations.missing_evidence rejects arrays with unknown elements" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        assert_db_rejects(determination, missing_evidence: [ "bogus_evidence" ])
        assert_db_rejects(determination, missing_evidence: %w[aian_attestation not_in_vocab])
      end
    end

    test "corvid_fmap_determinations.missing_evidence rejects jsonb scalars and objects" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        assert_db_rejects(determination, missing_evidence: "evidence_refs")
        assert_db_rejects(determination, missing_evidence: { "evidence_refs" => true })
      end
    end

    test "corvid_fmap_determinations.missing_evidence accepts FmapClassificationService vocabulary" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        assert_db_accepts(determination, missing_evidence: [])
        MISSING_EVIDENCE_VOCABULARY.each do |item|
          assert_db_accepts(determination, missing_evidence: [ item ])
        end
        assert_db_accepts(determination, missing_evidence: MISSING_EVIDENCE_VOCABULARY)
      end
    end

    test "FmapDetermination model rejects missing_evidence elements outside vocabulary before the database" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        determination.missing_evidence = [ "bogus_evidence" ]
        refute determination.valid?
        assert determination.errors[:missing_evidence].present?
      end
    end

    test "corvid_fmap_determinations.best_available_rule_key rejects unknown rule keys" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        assert_db_rejects(determination, best_available_rule_key: "no-such-rule-key")
      end
    end

    test "corvid_fmap_determinations.best_available_rule_key accepts shipped rule keys and NULL" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        assert_db_accepts(determination, best_available_rule_key: "us-regular")
        assert_db_accepts(determination, best_available_rule_key: nil)
      end
    end

    test "corvid_fmap_determinations.rule_key rejects unknown rule keys" do
      with_tenant(TENANT) do
        determination = create_fmap_determination_with_rule!
        assert_db_rejects(determination, rule_key: "no-such-rule-key")
      end
    end

    test "corvid_fmap_determinations.rule_key accepts shipped rule keys and NULL" do
      with_tenant(TENANT) do
        determination = create_fmap_determination!
        assert_db_accepts(determination, rule_key: nil)

        determination_with_rule = create_fmap_determination_with_rule!
        assert_db_accepts(determination_with_rule, rule_key: "us-regular")
      end
    end

    private

    def assert_db_rejects(record, attrs)
      error = assert_raises(ActiveRecord::StatementInvalid) do
        record.class.transaction(requires_new: true) do
          record.update_columns(attrs)
        end
      end
      message = error.cause&.message || error.message
      assert(
        message.match?(/check constraint|foreign key|violates/i),
        "expected CHECK or FK violation, got: #{message}"
      )
    end

    def assert_db_accepts(record, attrs)
      record.class.transaction(requires_new: true) do
        record.update_columns(attrs)
      end
      record.reload
      attrs.each do |key, expected|
        actual = record.public_send(key)
        if expected.nil?
          assert_nil actual, "expected #{key} to accept NULL"
        else
          assert_equal expected, actual, "expected #{key} to accept #{expected.inspect}"
        end
      end
    end

    def create_prc_referral!
      kase = Case.create!(patient_identifier: "pt_enum_#{SecureRandom.hex(3)}", facility_identifier: "fac_enum")
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_enum_#{SecureRandom.hex(4)}",
        facility_identifier: "fac_enum"
      )
    end

    def create_prc_eligibility_decision!
      PrcEligibilityDecision.create!(
        tenant_identifier: TENANT,
        person_identifier: "pt_elig_#{SecureRandom.hex(3)}",
        facility_identifier: "fac_enum",
        decided_at: Time.current,
        as_of_date: Date.current,
        eligible: false,
        reason_codes: [ "not_enrolled" ]
      )
    end

    def create_prc_overpayment_analysis!
      ob = PrcObligation.create!(
        facility_identifier: "fac_enum",
        obligation_id: "OBL-ENUM-#{SecureRandom.hex(4)}",
        imported_at: Time.current,
        billed_amount_cents: 10_000
      )
      PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_1.5",
        recovery_confidence: "clear",
        analyzed_at: Time.current
      )
    end

    def create_fmap_determination!
      FmapDetermination.create!(
        encounter_identifier: "enc_enum_#{SecureRandom.hex(4)}",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        category: "undetermined",
        determination_reason: FmapClassificationService::NO_RULES_IN_FORCE,
        determined_at: Time.current
      )
    end

    def create_fmap_determination_with_rule!
      rule = FmapRule.find_by!(rule_key: "us-regular")
      FmapDetermination.create!(
        encounter_identifier: "enc_enum_rule_#{SecureRandom.hex(4)}",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "US",
        category: "fmap_regular",
        rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent,
        rule_citations: [ rule.statutory_citation ],
        determined_at: Time.current
      )
    end
  end
end
