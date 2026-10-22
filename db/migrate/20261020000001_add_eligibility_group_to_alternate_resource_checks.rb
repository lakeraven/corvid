# frozen_string_literal: true

# ADR 0002 stores the Medicaid eligibility group, and the source of that
# determination, as strings and rejects any other value with a CHECK
# constraint. The group is meaningful only on a medicaid row. The group
# and its source are recorded together or not at all, and
# eligibility_group_set_at is present exactly when the group is present.
class AddEligibilityGroupToAlternateResourceChecks < ActiveRecord::Migration[8.1]
  ELIGIBILITY_GROUPS = %w[expansion_adult waiver_adult other unknown].freeze
  ELIGIBILITY_GROUP_SOURCES = %w[
    eligibility_response state_case_data registration staff_entry inferred
  ].freeze

  def up
    add_eligibility_group_columns
    add_eligibility_group_checks
  end

  def down
    remove_eligibility_group_checks
    remove_eligibility_group_columns
  end

  private

  def add_eligibility_group_columns
    add_column :corvid_alternate_resource_checks, :eligibility_group, :string
    add_column :corvid_alternate_resource_checks, :eligibility_group_source, :string
    add_column :corvid_alternate_resource_checks, :eligibility_group_set_at, :datetime
  end

  def remove_eligibility_group_columns
    remove_column :corvid_alternate_resource_checks, :eligibility_group_set_at
    remove_column :corvid_alternate_resource_checks, :eligibility_group_source
    remove_column :corvid_alternate_resource_checks, :eligibility_group
  end

  def add_eligibility_group_checks
    add_check_constraint :corvid_alternate_resource_checks,
      group_sql,
      name: "corvid_arc_eligibility_group_check"
    add_check_constraint :corvid_alternate_resource_checks,
      source_sql,
      name: "corvid_arc_eligibility_group_source_check"
    add_check_constraint :corvid_alternate_resource_checks,
      medicaid_only_sql,
      name: "corvid_arc_eligibility_group_medicaid_only_check"
    add_check_constraint :corvid_alternate_resource_checks,
      pair_sql,
      name: "corvid_arc_eligibility_group_pair_check"
    add_check_constraint :corvid_alternate_resource_checks,
      set_at_sql,
      name: "corvid_arc_eligibility_group_set_at_check"
  end

  def remove_eligibility_group_checks
    %w[
      corvid_arc_eligibility_group_set_at_check
      corvid_arc_eligibility_group_pair_check
      corvid_arc_eligibility_group_medicaid_only_check
      corvid_arc_eligibility_group_source_check
      corvid_arc_eligibility_group_check
    ].each do |name|
      remove_check_constraint :corvid_alternate_resource_checks, name: name
    end
  end

  def group_sql
    "eligibility_group IS NULL OR eligibility_group IN (#{quoted(ELIGIBILITY_GROUPS)})"
  end

  def source_sql
    "eligibility_group_source IS NULL OR eligibility_group_source IN (#{quoted(ELIGIBILITY_GROUP_SOURCES)})"
  end

  def medicaid_only_sql
    "eligibility_group IS NULL OR resource_type = 'medicaid'"
  end

  def pair_sql
    <<~SQL.squish
      (eligibility_group IS NULL AND eligibility_group_source IS NULL) OR
      (eligibility_group IS NOT NULL AND eligibility_group_source IS NOT NULL)
    SQL
  end

  def set_at_sql
    <<~SQL.squish
      (eligibility_group IS NULL AND eligibility_group_set_at IS NULL) OR
      (eligibility_group IS NOT NULL AND eligibility_group_set_at IS NOT NULL)
    SQL
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(",")
  end
end
