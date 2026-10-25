# frozen_string_literal: true

# ADR 0002: these columns are string enums (or code-shaped strings). The
# CHECK / foreign key is what stops a raw write from storing an arbitrary
# value. Vocabularies were re-derived from the writers, not copied blindly:
#   priority_system       — MedicalPriorityService ("corvid_v1" only)
#   provider_confidence   — Adapters::Base::TRIBAL_CONFIDENCE_VALUES
#   payment_system        — PrcOverpaymentAnalyzer (:pfs, :ipps, :asc, :opps)
#   recovery_confidence   — PrcOverpaymentAnalyzer's six confidence levels
#   missing_evidence      — FmapClassificationService::MISSING_EVIDENCE
#   jurisdiction          — two uppercase letters
# best_available_rule_key and rule_key both reference
# corvid_fmap_rules.rule_key. corvid_care_team_members.role is free text
# ("Care Manager", "Lead 1") and is not checked here; that is #705.
#
# corvid_prc_obligations.status is an external report code. Its vocabulary
# is the owner's decision, still pending, so this migration does not
# constrain it.
#
# closure_reason has no readers or writers. provider_type has no writers,
# and a token shape would still accept PHI-like values. up drops both.
# down adds the nullable string columns back; there is no data to put in
# them.
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
  # Same six terms as FmapClassificationService::MISSING_EVIDENCE. The CHECK
  # is fixed in this migration and does not read the constant.
  MISSING_EVIDENCE = %w[
    evidence_refs aian_attestation received_through_basis aian_status_evidence
    care_coordination_agreement received_through_evidence
  ].freeze

  JURISDICTION = "^[A-Z]{2}$"
  RULE_KEY_COLUMNS = [ :best_available_rule_key, :rule_key ].freeze

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
    [ :corvid_fmap_determinations, :jurisdiction, "corvid_fmap_determinations_jurisdiction_check",
      JURISDICTION, false ]
  ].freeze

  MISSING_EVIDENCE_CHECK = "corvid_fmap_determinations_missing_evidence_check"

  def up
    apply_constraints!
    reset_column_caches!
  end

  def down
    connection.transaction(requires_new: true) do
      add_column :corvid_cases, :closure_reason, :string, if_not_exists: true
      add_column :corvid_claim_submissions, :provider_type, :string, if_not_exists: true
      remove_rule_key_fks!
      remove_named_check(:corvid_fmap_determinations, MISSING_EVIDENCE_CHECK)
      SHAPE_CHECKS.reverse_each { |check| remove_named_check(check[0], check[2]) }
      VALUE_CHECKS.reverse_each { |check| remove_named_check(check[0], check[2]) }
    end
    reset_column_caches!
  end

  private

  def apply_constraints!
    connection.transaction(requires_new: true) do
      VALUE_CHECKS.each { |check| add_value_check!(*check) }
      SHAPE_CHECKS.each { |check| add_shape_check!(*check) }
      add_missing_evidence_check!
      add_rule_key_fks!
      remove_column :corvid_cases, :closure_reason, :string, if_exists: true
      remove_column :corvid_claim_submissions, :provider_type, :string, if_exists: true
    end
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

  def add_rule_key_fks!
    RULE_KEY_COLUMNS.each { |column| add_rule_key_fk!(column) }
  end

  def add_rule_key_fk!(column)
    refuse_violations!(:corvid_fmap_determinations, column, unknown_rule_key_sql(column))
    add_foreign_key :corvid_fmap_determinations, :corvid_fmap_rules,
                    column: column, primary_key: :rule_key, if_not_exists: true
  end

  def remove_rule_key_fks!
    RULE_KEY_COLUMNS.reverse_each do |column|
      remove_foreign_key :corvid_fmap_determinations, :corvid_fmap_rules,
                         column: column, if_exists: true
    end
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

  # Count query only. A foreign key cannot be expressed as a CHECK:
  # Postgres rejects subqueries in CHECK constraints.
  def unknown_rule_key_sql(column)
    <<~SQL.squish
      #{column} IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM corvid_fmap_rules
        WHERE corvid_fmap_rules.rule_key = corvid_fmap_determinations.#{column}
      )
    SQL
  end

  def sql_list(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end

  def remove_named_check(table, name)
    remove_check_constraint table, name: name, if_exists: true
  end

  def reset_column_caches!
    Corvid::Case.reset_column_information if defined?(Corvid::Case)
    Corvid::ClaimSubmission.reset_column_information if defined?(Corvid::ClaimSubmission)
  end
end
