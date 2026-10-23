# frozen_string_literal: true

# ADR 0002 stores the Medicaid application date, the source of that date,
# and the state whose rules apply as strings (the date is a date) and
# rejects any other value with a CHECK constraint. The date is meaningful
# only on a medicaid row. The date and its source are recorded together
# or not at all. The state code is two uppercase letters, or null.
class AddMedicaidApplicationToAlternateResourceChecks < ActiveRecord::Migration[8.1]
  APPLICATION_DATE_SOURCES = %w[
    eligibility_response state_case_data registration staff_entry inferred
  ].freeze

  def up
    add_application_columns
    add_application_checks
  end

  def down
    remove_application_checks
    remove_application_columns
  end

  private

  def add_application_columns
    add_column :corvid_alternate_resource_checks, :application_date, :date
    add_column :corvid_alternate_resource_checks, :application_date_source, :string
    add_column :corvid_alternate_resource_checks, :medicaid_state_code, :string
  end

  def remove_application_columns
    remove_column :corvid_alternate_resource_checks, :medicaid_state_code
    remove_column :corvid_alternate_resource_checks, :application_date_source
    remove_column :corvid_alternate_resource_checks, :application_date
  end

  def add_application_checks
    add_check_constraint :corvid_alternate_resource_checks,
      source_sql,
      name: "corvid_arc_application_date_source_check"
    add_check_constraint :corvid_alternate_resource_checks,
      state_code_sql,
      name: "corvid_arc_medicaid_state_code_check"
    add_check_constraint :corvid_alternate_resource_checks,
      pair_sql,
      name: "corvid_arc_application_date_pair_check"
    add_check_constraint :corvid_alternate_resource_checks,
      medicaid_only_sql,
      name: "corvid_arc_application_date_medicaid_only_check"
  end

  def remove_application_checks
    %w[
      corvid_arc_application_date_medicaid_only_check
      corvid_arc_application_date_pair_check
      corvid_arc_medicaid_state_code_check
      corvid_arc_application_date_source_check
    ].each do |name|
      remove_check_constraint :corvid_alternate_resource_checks, name: name
    end
  end

  def source_sql
    "application_date_source IS NULL OR application_date_source IN (#{quoted(APPLICATION_DATE_SOURCES)})"
  end

  def state_code_sql
    "medicaid_state_code IS NULL OR medicaid_state_code ~ '^[A-Z]{2}$'"
  end

  def pair_sql
    <<~SQL.squish
      (application_date IS NULL AND application_date_source IS NULL) OR
      (application_date IS NOT NULL AND application_date_source IS NOT NULL)
    SQL
  end

  def medicaid_only_sql
    <<~SQL.squish
      (
        application_date IS NULL AND
        application_date_source IS NULL AND
        medicaid_state_code IS NULL
      ) OR resource_type = 'medicaid'
    SQL
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(",")
  end
end
