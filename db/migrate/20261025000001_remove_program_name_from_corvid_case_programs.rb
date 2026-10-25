# frozen_string_literal: true

# #591 classified corvid_case_programs.program_name as patient PHI. The column
# is also redundant: program_code is NOT NULL, unique per case, and validated
# against Corvid::ProgramRegistry, which owns the display name.
#
# up drops the column. Stored labels that differ from the registry display
# name are discarded; export them before migrating.
#
# down re-adds a nullable string, backfills each row from ProgramRegistry
# (stripped display_name, or program_code when the entry is missing or the
# display name is blank — the same rule as Corvid::CaseProgram#program_name),
# then sets NOT NULL. The backfill uses a migration-local model, not
# Corvid::CaseProgram, so it does not depend on the app model's tenant scope
# or its derived reader.
class RemoveProgramNameFromCorvidCasePrograms < ActiveRecord::Migration[8.1]
  class CaseProgramRow < ::ActiveRecord::Base
    self.table_name = "corvid_case_programs"
  end

  def up
    remove_column :corvid_case_programs, :program_name
  end

  def down
    add_column :corvid_case_programs, :program_name, :string
    backfill_program_names
    change_column_null :corvid_case_programs, :program_name, false
  end

  private

  def backfill_program_names
    CaseProgramRow.reset_column_information
    CaseProgramRow.find_each do |row|
      row.update_columns(program_name: registry_program_name(row.program_code))
    end
  end

  # Same rule as Corvid::CaseProgram#program_name.
  def registry_program_name(program_code)
    entry = Corvid::ProgramRegistry.find(program_code)
    entry&.display_name.to_s.strip.presence || program_code
  end
end
