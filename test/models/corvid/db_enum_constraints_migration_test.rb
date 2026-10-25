# frozen_string_literal: true

require "test_helper"

module Corvid
  # Reversible migration spec for AddDbConstraintsForUnboundedEnumColumns (#704).
  class DbEnumConstraintsMigrationTest < ActiveSupport::TestCase
    TENANT = "tnt_db_enum_migration"

    PRIORITY_SYSTEM_VALUES = %w[corvid_v1].freeze
    PROVIDER_CONFIDENCE_VALUES = %w[verified stale unavailable].freeze
    PAYMENT_SYSTEM_VALUES = %w[pfs ipps asc opps].freeze
    RECOVERY_CONFIDENCE_VALUES = %w[
      clear stub_estimate no_rate_for_year unmapped_procedure unmapped_facility missing_service_date
    ].freeze
    MISSING_EVIDENCE_VOCABULARY = %w[
      evidence_refs aian_attestation received_through_basis aian_status_evidence
      care_coordination_agreement received_through_evidence
    ].freeze

    CONSTRAINT_CHECKS = [
      {
        table: "corvid_prc_referrals",
        name: "corvid_prc_referrals_priority_system_check",
        factory: :prc_referral,
        reject: { priority_system: "legacy_unconstrained" },
        accept: PRIORITY_SYSTEM_VALUES.map { |value| { priority_system: value } } + [ { priority_system: nil } ]
      },
      {
        table: "corvid_prc_eligibility_decisions",
        name: "corvid_prc_eligibility_decisions_provider_confidence_check",
        factory: :prc_eligibility_decision,
        reject: { provider_confidence: "guesswork" },
        accept: PROVIDER_CONFIDENCE_VALUES.map { |value| { provider_confidence: value } } +
                [ { provider_confidence: nil } ]
      },
      {
        table: "corvid_prc_overpayment_analyses",
        name: "corvid_prc_overpayment_analyses_payment_system_check",
        factory: :prc_overpayment_analysis,
        reject: { payment_system: "medicare_part_b" },
        accept: PAYMENT_SYSTEM_VALUES.map { |value| { payment_system: value } } + [ { payment_system: nil } ]
      },
      {
        table: "corvid_prc_overpayment_analyses",
        name: "corvid_prc_overpayment_analyses_recovery_confidence_check",
        factory: :prc_overpayment_analysis,
        reject: { recovery_confidence: "maybe" },
        accept: RECOVERY_CONFIDENCE_VALUES.map { |value| { recovery_confidence: value } }
      },
      {
        table: "corvid_fmap_determinations",
        name: "corvid_fmap_determinations_jurisdiction_check",
        factory: :fmap_determination,
        reject: { jurisdiction: "usa" },
        accept: %w[US XA NY].map { |value| { jurisdiction: value } }
      },
      {
        table: "corvid_fmap_determinations",
        name: "corvid_fmap_determinations_missing_evidence_check",
        factory: :fmap_determination,
        reject: { missing_evidence: [ "bogus_evidence" ] },
        accept: [ { missing_evidence: [] } ] +
                MISSING_EVIDENCE_VOCABULARY.map { |item| { missing_evidence: [ item ] } }
      }
    ].freeze

    FOREIGN_KEYS = [
      {
        table: "corvid_fmap_determinations",
        column: "best_available_rule_key",
        factory: :fmap_determination,
        reject: { best_available_rule_key: "no-such-rule-key" },
        accept: { best_available_rule_key: "us-regular" },
        accept_null: { best_available_rule_key: nil }
      },
      {
        table: "corvid_fmap_determinations",
        column: "rule_key",
        factory: :fmap_determination_with_rule,
        reject: { rule_key: "no-such-rule-key" },
        accept: { rule_key: "us-regular" },
        accept_null: { rule_key: nil }
      }
    ].freeze

    teardown do
      restore_constraints_up_state!
    end

    test "migrate down drops enum constraints and restores closure_reason and provider_type" do
      migration = require_constraints_migration!

      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
      reset_column_information

      with_tenant(TENANT) do
        referral = create_prc_referral!
        assert_db_accepts_update(referral, priority_system: "legacy_unconstrained")
        referral.destroy!
      end

      assert_includes Case.column_names, "closure_reason",
                      "migrate down should restore the dropped closure_reason column"

      assert_includes ClaimSubmission.column_names, "provider_type",
                      "migrate down should restore the dropped provider_type column"
      provider_type_column = ClaimSubmission.columns.find { |column| column.name == "provider_type" }
      assert_equal :string, provider_type_column.type
      assert provider_type_column.null, "provider_type should be nullable after migrate down"

      with_tenant(TENANT) do
        claim = create_claim_submission!
        assert_db_accepts_update(claim, provider_type: "free-form-token")
      end
    end

    test "migrate down then up applies and removes every #704 database constraint" do
      migration = require_constraints_migration!
      FmapRuleLoader.load_defaults! if defined?(FmapRuleLoader)

      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
      reset_column_information

      assert_includes Case.column_names, "closure_reason"
      assert_includes ClaimSubmission.column_names, "provider_type"

      with_tenant(TENANT) do
        CONSTRAINT_CHECKS.each do |spec|
          refute check_constraint_exists?(spec[:table], spec[:name]),
                 "migrate down should drop #{spec[:name]}"
          record = build_factory_record!(spec[:factory])
          assert_db_accepts_update(record, spec[:reject])
        end

        FOREIGN_KEYS.each do |spec|
          refute foreign_key_exists?(spec[:table], spec[:column]),
                 "migrate down should drop FK on #{spec[:table]}.#{spec[:column]}"
          record = build_factory_record!(spec[:factory])
          assert_db_accepts_update(record, spec[:reject])
        end

        obligation = create_prc_obligation!
        assert_db_accepts_update(obligation, status: "OPEN")
        assert_db_accepts_update(obligation, status: "")

        delete_synthetic_migration_rows!
      end

      ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      reset_column_information

      refute_includes Case.column_names, "closure_reason"
      refute_includes ClaimSubmission.column_names, "provider_type"

      with_tenant(TENANT) do
        CONSTRAINT_CHECKS.each do |spec|
          assert check_constraint_exists?(spec[:table], spec[:name]),
                 "migrate up should add #{spec[:name]}"
          record = build_factory_record!(spec[:factory])
          assert_db_rejects_update(record, spec[:reject])

          spec[:accept].each do |attrs|
            assert_db_accepts_update(record, attrs)
          end

          if spec[:name] == "corvid_fmap_determinations_jurisdiction_check"
            record = build_factory_record!(:fmap_determination)
            assert_db_rejects_update(record, jurisdiction: "NYC")
            assert_db_rejects_update(record, jurisdiction: "ny")
          end

          if spec[:name] == "corvid_fmap_determinations_missing_evidence_check"
            record = build_factory_record!(:fmap_determination)
            assert_db_rejects_update(record, missing_evidence: "evidence_refs")
            assert_db_rejects_update(record, missing_evidence: { "evidence_refs" => true })
          end
        end

        FOREIGN_KEYS.each do |spec|
          assert foreign_key_exists?(spec[:table], spec[:column]),
                 "migrate up should add FK on #{spec[:table]}.#{spec[:column]}"
          record = build_factory_record!(spec[:factory])
          assert_db_rejects_update(record, spec[:reject])
          assert_db_accepts_update(record, spec[:accept])
          assert_db_accepts_update(record, spec[:accept_null]) if spec[:accept_null]
        end
      end
    end

    test "migrate up fails loudly when existing rows violate new constraints" do
      migration = require_constraints_migration!
      violating_value = "legacy_unconstrained"

      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }

      with_tenant(TENANT) do
        referral = create_prc_referral!
        assert_db_accepts_update(referral, priority_system: violating_value)
      end

      error = assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      end

      message = error.message
      assert_match(/corvid_prc_referrals/, message)
      assert_match(/priority_system/, message)
      assert_match(/1 violating row/, message)
      refute_includes message, violating_value

      with_tenant(TENANT) do
        referral = PrcReferral.order(:id).last
        assert_equal violating_value, referral.priority_system,
                     "migrate up must not coerce violating data"
        referral.update_columns(priority_system: PRIORITY_SYSTEM_VALUES.first)
      end

      ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      reset_column_information

      with_tenant(TENANT) do
        referral = PrcReferral.order(:id).last
        assert_db_rejects_update(referral, priority_system: violating_value)
      end
    end

    test "migrate up counts unknown rule keys without echoing key values" do
      migration = require_constraints_migration!
      FmapRuleLoader.load_defaults! if defined?(FmapRuleLoader)

      specs = [
        {
          factory: :fmap_determination,
          column: "best_available_rule_key",
          apply_violation: ->(record, bad_key) { record.update_columns(best_available_rule_key: bad_key) },
          clear_violation: ->(record) { record.update_columns(best_available_rule_key: nil) }
        },
        {
          factory: :fmap_determination_with_rule,
          column: "rule_key",
          apply_violation: ->(record, bad_key) { record.update_columns(rule_key: bad_key) },
          clear_violation: ->(record) { record.update_columns(rule_key: "us-regular") }
        }
      ]

      specs.each do |spec|
        bad_key = "no-such-rule-#{SecureRandom.hex(3)}"
        record = nil

        ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }

        begin
          with_tenant(TENANT) do
            record = build_factory_record!(spec[:factory])
            spec[:apply_violation].call(record, bad_key)
          end

          error = assert_raises(ActiveRecord::StatementInvalid) do
            ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
          end

          message = error.message
          assert_match(/corvid_fmap_determinations/, message)
          assert_match(/#{spec[:column]}/, message)
          assert_match(/1 violating row/, message)
          refute_includes message, bad_key
        ensure
          with_tenant(TENANT) do
            if record&.persisted?
              record.reload
              spec[:clear_violation].call(record)
            end
          end
          ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
          reset_column_information
        end
      end
    end

    test "migration vocabulary constants match application writers" do
      require_constraints_migration!
      assert_equal PrcReferral::PRIORITY_SYSTEMS, AddDbConstraintsForUnboundedEnumColumns::PRIORITY_SYSTEMS
      assert_equal PrcEligibilityDecision::PROVIDER_CONFIDENCES,
                   AddDbConstraintsForUnboundedEnumColumns::PROVIDER_CONFIDENCES
      assert_equal PrcOverpaymentAnalysis::PAYMENT_SYSTEMS,
                   AddDbConstraintsForUnboundedEnumColumns::PAYMENT_SYSTEMS
      assert_equal PrcOverpaymentAnalysis::RECOVERY_CONFIDENCES,
                   AddDbConstraintsForUnboundedEnumColumns::RECOVERY_CONFIDENCES
      assert_equal FmapClassificationService::MISSING_EVIDENCE,
                   AddDbConstraintsForUnboundedEnumColumns::MISSING_EVIDENCE
    end

    private

    def constraints_migration_paths
      Dir[
        Rails.root.join("db/migrate/*_add_db_constraints_for_unbounded_enum_columns.rb").to_s,
        Corvid::Engine.root.join("db/migrate/*_add_db_constraints_for_unbounded_enum_columns.rb").to_s
      ]
    end

    def require_constraints_migration!
      paths = constraints_migration_paths
      flunk "expected migration file matching *_add_db_constraints_for_unbounded_enum_columns.rb" if paths.empty?

      path = paths.first
      require path unless defined?(AddDbConstraintsForUnboundedEnumColumns)
      AddDbConstraintsForUnboundedEnumColumns.new
    end

    def restore_constraints_up_state!
      return if constraints_migration_paths.empty?
      return unless defined?(AddDbConstraintsForUnboundedEnumColumns)

      ActiveRecord::Migration.suppress_messages do
        AddDbConstraintsForUnboundedEnumColumns.new.migrate(:up)
      end
      reset_column_information
    end

    def reset_column_information
      [
        Case, PrcReferral, PrcEligibilityDecision, PrcObligation, PrcOverpaymentAnalysis,
        CareTeamMember, ClaimSubmission, FmapDetermination, FmapRule
      ].each(&:reset_column_information)
    end

    def check_constraint_exists?(table, name)
      sql = <<~SQL.squish
        SELECT 1
        FROM pg_constraint c
        INNER JOIN pg_class t ON c.conrelid = t.oid
        WHERE t.relname = #{connection.quote(table)}
          AND c.conname = #{connection.quote(name)}
          AND c.contype = 'c'
        LIMIT 1
      SQL
      connection.select_value(sql).present?
    end

    def foreign_key_exists?(table, column)
      connection.foreign_keys(table).any? { |fk| fk.column == column }
    end

    def connection
      ActiveRecord::Base.connection
    end

    def delete_synthetic_migration_rows!
      PrcPayment.delete_all
      PrcOverpaymentAnalysis.delete_all
      PrcObligation.delete_all
      PrcEligibilityDecision.where(tenant_identifier: TENANT).delete_all
      PrcReferral.delete_all
      Case.where(facility_identifier: "fac_mig").delete_all
      FmapDetermination.delete_all
      ClaimSubmission.delete_all
    end

    def build_factory_record!(factory)
      case factory
      when :prc_referral then create_prc_referral!
      when :prc_eligibility_decision then create_prc_eligibility_decision!
      when :prc_overpayment_analysis then create_prc_overpayment_analysis!
      when :fmap_determination then create_fmap_determination!
      when :fmap_determination_with_rule then create_fmap_determination_with_rule!
      else
        flunk "unknown factory #{factory}"
      end
    end

    def assert_db_rejects_update(record, attrs)
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

    def assert_db_accepts_update(record, attrs)
      record.class.transaction(requires_new: true) do
        record.update_columns(attrs)
      end
      record.reload
    end

    def create_prc_referral!
      kase = Case.create!(patient_identifier: "pt_mig_#{SecureRandom.hex(3)}", facility_identifier: "fac_mig")
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_mig_#{SecureRandom.hex(4)}",
        facility_identifier: "fac_mig"
      )
    end

    def create_prc_eligibility_decision!
      PrcEligibilityDecision.create!(
        tenant_identifier: TENANT,
        person_identifier: "pt_elig_mig_#{SecureRandom.hex(3)}",
        facility_identifier: "fac_mig",
        decided_at: Time.current,
        as_of_date: Date.current,
        eligible: false,
        reason_codes: [ "not_enrolled" ]
      )
    end

    def create_prc_obligation!
      PrcObligation.create!(
        facility_identifier: "fac_mig",
        obligation_id: "OBL-MIG-#{SecureRandom.hex(4)}",
        imported_at: Time.current,
        billed_amount_cents: 10_000
      )
    end

    def create_prc_overpayment_analysis!
      ob = create_prc_obligation!
      PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_1.5",
        recovery_confidence: "clear",
        analyzed_at: Time.current
      )
    end

    def create_claim_submission!
      ClaimSubmission.create!(
        patient_identifier: "pt_claim_mig_#{SecureRandom.hex(3)}",
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 100.0
      )
    end

    def create_fmap_determination!
      FmapDetermination.create!(
        encounter_identifier: "enc_mig_#{SecureRandom.hex(4)}",
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
        encounter_identifier: "enc_mig_rule_#{SecureRandom.hex(4)}",
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
