# frozen_string_literal: true

class CreateCorvidCasePrograms < ActiveRecord::Migration[8.1]
  ENROLLMENT_STATUSES = %w[active inactive pending terminated].freeze

  def change
    create_table :corvid_case_programs do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :case, null: false, foreign_key: { to_table: :corvid_cases }
      t.string :program_name, null: false
      t.string :program_code, null: false
      t.string :enrollment_status, null: false, default: "active"
      t.date :enrollment_date, null: false
      t.date :disenrollment_date
      t.timestamps
    end

    add_index :corvid_case_programs, [:tenant_identifier, :facility_identifier], name: "idx_corvid_case_programs_tenant_facility"
    add_index :corvid_case_programs, [:case_id, :program_code], unique: true, name: "idx_corvid_case_programs_case_code"
    add_index :corvid_case_programs, [:tenant_identifier, :enrollment_status], name: "idx_corvid_case_programs_tenant_status"
    add_check_constraint :corvid_case_programs,
      "enrollment_status IN (#{ENROLLMENT_STATUSES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_case_programs_enrollment_status_check"
  end
end
