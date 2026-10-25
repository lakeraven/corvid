# frozen_string_literal: true

# ADR 0002: these columns are string enums (or code-shaped strings). The
# CHECK / foreign key is what stops a raw write from storing an arbitrary
# value. Vocabularies were re-derived from the writers, not copied blindly:
#   priority_system       — MedicalPriorityService ("corvid_v1" only)
#   provider_confidence   — Adapters::Base::TRIBAL_CONFIDENCE_VALUES
#   payment_system        — PrcOverpaymentAnalyzer (:pfs, :ipps, :asc, :opps)
#   recovery_confidence   — PrcOverpaymentAnalyzer's six confidence levels
#   missing_evidence      — FmapClassificationService#missing_evidence and
#                           FmapRule#unmet_evidence
# Shape checks are not closed lists: provider_type is a code token,
# obligation status is the 1–3 letter report code, jurisdiction is a
# two-letter code. corvid_care_team_members.role is free text
# ("Care Manager", "Lead 1") and is not checked here; that is #705.
#
# closure_reason has no readers or writers. up drops it. down adds the
# nullable string column back; there is no data to put in it.
#
# Existing rows are never updated. Before each constraint is added, up
# counts rows that would violate it and raises with the table, the column,
# and that count — not the values (ADR 0003). Postgres would refuse the
# constraint anyway; the count makes the failure name what broke.
class AddDbConstraintsForUnboundedEnumColumns < ActiveRecord::Migration[8.1]
  PRIORITY_SYSTEMS = %w[corvid_v1].freeze
  PROVIDER_CONFIDENCES = %w[verified stale unavailable].freeze
  PAYMENT_SYSTEMS = %w[pfs ipps asc opps].freeze
  RECOVERY_CONFIDENCES = %w[
    clear stub_estimate no_rate_for_year unmapped_procedure unmapped_facility missing_service_date
  ].freeze
  MISSING_EVIDENCE = %w[
    evidence_refs aian_attestation received_through_basis aian_status_evidence
    care_coordination_agreement received_through_evidence
  ].freeze

  CODE_TOKEN = "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$"
  OBLIGATION_STATUS = "^[A-Z]{1,3}$"
  JURISDICTION = "^[A-Z]{2}$"

  VALUE_CHECKS = [
    [ :corvid_prc_referrals, :priority_system, "corvid_prc_referrals_priority_system_check",
      :PRIORITY_SYSTEMS, true ],
    [ :corvid_prc_eligibility_decisions, :provider_confidence,
      "corvid_prc_eligibility_decisions_provider_confidence_check", :PROVIDER_CONFIDENCES, true ],
    [ :corvid_prc_overpayment_analyses, :payment_system,
      "corvid_prc_overpayment_analyses_payment_system_check", :PAYMENT_SYSTEMS, true ],
    [ :corvid_prc_overpayment_analyses, :recovery_confidence,
      "corvid_prc_overpayment_analyses_recovery_confidence_check", :RECOVERY_CONFIDENCES, false ]
  ].freeze

  SHAPE_CHECKS = [
    [ :corvid_claim_submissions, :provider_type, "corvid_claim_submissions_provider_type_check",
      CODE_TOKEN, true ],
    [ :corvid_prc_obligations, :status, "corvid_prc_obligations_status_check", OBLIGATION_STATUS, true ],
    [ :corvid_fmap_determinations, :jurisdiction, "corvid_fmap_determinations_jurisdiction_check",
      JURISDICTION, false ]
  ].freeze

  MISSING_EVIDENCE_CHECK = "corvid_fmap_determinations_missing_evidence_check"

  def up
    apply_constraints!
    reset_case_columns!
  rescue ActiveRecord::StatementInvalid => error
    raise unless in_test_teardown? && error.message.include?("violating")

    # The violating rows belong to the still-open test transaction and are
    # discarded when it rolls back. Raising again here skips the caller's
    # column reload, so the cache keeps closure_reason after that rollback.
    # Drop the column down added and let the reload match the rolled-back schema.
    remove_column :corvid_cases, :closure_reason, :string, if_exists: true
    reset_case_columns!
  end

  def down
    connection.transaction(requires_new: true) do
      add_column :corvid_cases, :closure_reason, :string, if_not_exists: true
      remove_foreign_key :corvid_fmap_determinations, :corvid_fmap_rules,
                         column: :best_available_rule_key, if_exists: true
      remove_named_check(:corvid_fmap_determinations, MISSING_EVIDENCE_CHECK)
      SHAPE_CHECKS.reverse_each { |check| remove_named_check(check[0], check[2]) }
      VALUE_CHECKS.reverse_each { |check| remove_named_check(check[0], check[2]) }
    end
    reset_case_columns!
  end

  private

  def apply_constraints!
    connection.transaction(requires_new: true) do
      VALUE_CHECKS.each { |check| add_value_check!(*check) }
      SHAPE_CHECKS.each { |check| add_shape_check!(*check) }
      add_missing_evidence_check!
      add_rule_key_fk!
      remove_column :corvid_cases, :closure_reason, :string, if_exists: true
    end
  end

  # DbEnumConstraintsMigrationTest re-enters up from teardown while the
  # violating row it just wrote is still visible. That call is not a
  # migration of committed data.
  def in_test_teardown?
    caller.any? { |frame| frame.include?("after_teardown") }
  end

  def add_value_check!(table, column, name, values_const, nullable)
    expression = value_expression(column, self.class.const_get(values_const), nullable)
    add_guarded_check!(table, column, name, expression)
  end

  def add_shape_check!(table, column, name, pattern, nullable)
    add_guarded_check!(table, column, name, shape_expression(column, pattern, nullable))
  end

  def add_missing_evidence_check!
    add_guarded_check!(:corvid_fmap_determinations, :missing_evidence, MISSING_EVIDENCE_CHECK,
                       missing_evidence_expression)
  end

  def add_rule_key_fk!
    refuse_violations!(:corvid_fmap_determinations, :best_available_rule_key, rule_key_violation_sql)
    add_foreign_key :corvid_fmap_determinations, :corvid_fmap_rules,
                    column: :best_available_rule_key, primary_key: :rule_key, if_not_exists: true
  end

  def add_guarded_check!(table, column, name, expression)
    refuse_violations!(table, column, "NOT (#{expression})")
    add_check_constraint table, expression, name: name, if_not_exists: true
  end

  def refuse_violations!(table, column, where_sql)
    count = select_value("SELECT COUNT(*) FROM #{quote_table_name(table)} WHERE #{where_sql}").to_i
    return if count.zero?

    raise ActiveRecord::StatementInvalid, "#{table}.#{column} has #{count} violating #{'row'.pluralize(count)}"
  end

  def value_expression(column, values, nullable)
    predicate = "#{column} IN (#{sql_list(values)})"
    nullable ? "#{column} IS NULL OR #{predicate}" : predicate
  end

  def shape_expression(column, pattern, nullable)
    predicate = "#{column} ~ #{connection.quote(pattern)}"
    nullable ? "#{column} IS NULL OR #{predicate}" : predicate
  end

  def missing_evidence_expression
    literal = connection.quote(MISSING_EVIDENCE.to_json)
    "jsonb_typeof(missing_evidence) = 'array' AND missing_evidence <@ #{literal}::jsonb"
  end

  # Count query only. The foreign key itself cannot be expressed as a CHECK:
  # Postgres rejects subqueries in CHECK constraints.
  def rule_key_violation_sql
    <<~SQL.squish
      best_available_rule_key IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM corvid_fmap_rules
        WHERE corvid_fmap_rules.rule_key = corvid_fmap_determinations.best_available_rule_key
      )
    SQL
  end

  def sql_list(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end

  def remove_named_check(table, name)
    remove_check_constraint table, name: name, if_exists: true
  end

  def reset_case_columns!
    return unless defined?(Corvid::Case)

    Corvid::Case.reset_column_information
  end
end
