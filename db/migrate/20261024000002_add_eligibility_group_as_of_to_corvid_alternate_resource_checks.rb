# frozen_string_literal: true

# Issue #695: when the source produced a stated Medicaid eligibility
# group. Null when that time is unknown. A timestamp is allowed only
# with a stated source (ADR 0002). Staff entry and inference stay null.
class AddEligibilityGroupAsOfToCorvidAlternateResourceChecks < ActiveRecord::Migration[8.1]
  STATED_SOURCES = %w[eligibility_response state_case_data registration].freeze
  CHECK_NAME = "corvid_arc_eligibility_group_as_of_stated_source_check"

  def up
    add_column :corvid_alternate_resource_checks, :eligibility_group_as_of, :datetime
    add_check_constraint :corvid_alternate_resource_checks, as_of_sql, name: CHECK_NAME
  end

  def down
    remove_check_constraint :corvid_alternate_resource_checks, name: CHECK_NAME
    remove_column :corvid_alternate_resource_checks, :eligibility_group_as_of
  end

  private

  def as_of_sql
    "eligibility_group_as_of IS NULL OR (eligibility_group_source IS NOT NULL AND eligibility_group_source IN (#{quoted(STATED_SOURCES)}))"
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(",")
  end
end
