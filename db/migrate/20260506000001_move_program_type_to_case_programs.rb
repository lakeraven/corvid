# frozen_string_literal: true

class MoveProgramTypeToCasePrograms < ActiveRecord::Migration[8.1]
  def up
    backfill_case_programs!

    remove_index :corvid_cases, %i[tenant_identifier program_type],
                 if_exists: true
    remove_column :corvid_cases, :program_type
  end

  def down
    add_column :corvid_cases, :program_type, :string
    add_index :corvid_cases, %i[tenant_identifier program_type]

    Corvid::Case.reset_column_information
    Corvid::Case.unscoped.find_each do |kase|
      cp = Corvid::CaseProgram.unscoped.where(case_id: kase.id).first
      next unless cp

      kase.update_column(:program_type, cp.program_code)
    end
  end

  private

  # For each case with a program_type set, ensure a corresponding CaseProgram
  # row exists. Idempotent: skips when a row already exists for the same
  # case + program_code.
  def backfill_case_programs!
    return unless column_exists?(:corvid_cases, :program_type)

    Corvid::Case.reset_column_information
    Corvid::Case.unscoped.where.not(program_type: nil).find_each do |kase|
      next if Corvid::CaseProgram.unscoped
                                 .where(case_id: kase.id, program_code: kase.program_type)
                                 .exists?

      Corvid::CaseProgram.unscoped.create!(
        case_id: kase.id,
        tenant_identifier: kase.tenant_identifier,
        facility_identifier: kase.facility_identifier,
        program_code: kase.program_type,
        program_name: registry_display_name(kase.program_type),
        enrollment_date: kase.intake_at&.to_date || kase.created_at.to_date,
        enrollment_status: 'active'
      )
    end
  end

  def registry_display_name(code)
    Corvid::ProgramRegistry.find(code)&.display_name || code
  end
end
