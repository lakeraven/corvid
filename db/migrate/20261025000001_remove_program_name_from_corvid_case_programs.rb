# frozen_string_literal: true

# #591 classified corvid_case_programs.program_name as patient PHI. The column
# is also redundant: program_code is NOT NULL, unique per case, and validated
# against Corvid::ProgramRegistry, which owns the display name.
#
# up drops the column only when every stored label matches the registry-derived
# name and every program_code is registered. Otherwise it raises
# UnmappedProgramNames with those two counts and nothing else (ADR 0003 — no
# labels, codes, or ids). Export the labels first, or set
# CORVID_DISCARD_PROGRAM_NAMES=1 to drop the column anyway.
#
# down re-adds a nullable string, backfills each row from ProgramRegistry
# (stripped display_name, or program_code when the entry is missing or the
# display name is blank — the same rule as Corvid::CaseProgram#program_name),
# then sets NOT NULL. up and down share that rule in one private method. The
# scan and the backfill use a migration-local model, not Corvid::CaseProgram,
# so they do not depend on the app model's tenant scope or its derived reader.
class RemoveProgramNameFromCorvidCasePrograms < ActiveRecord::Migration[8.1]
  # Counts only. The message must not carry stored labels, codes, or ids.
  class UnmappedProgramNames < StandardError; end

  class CaseProgramRow < ::ActiveRecord::Base
    self.table_name = "corvid_case_programs"
  end

  def up
    refuse_unmapped_program_names!
    remove_column :corvid_case_programs, :program_name
  end

  def down
    add_column :corvid_case_programs, :program_name, :string
    backfill_program_names
    change_column_null :corvid_case_programs, :program_name, false
  end

  private

  def refuse_unmapped_program_names!
    mismatched, unregistered = program_name_drift_counts
    return if mismatched.zero? && unregistered.zero?
    return if ENV["CORVID_DISCARD_PROGRAM_NAMES"] == "1"

    raise UnmappedProgramNames, unmapped_program_names_message(mismatched, unregistered)
  end

  def program_name_drift_counts
    mismatched = 0
    unregistered = 0

    each_case_program_row do |row|
      mismatched += 1 if row.program_name != registry_program_name(row.program_code)
      unregistered += 1 unless Corvid::ProgramRegistry.exists?(row.program_code)
    end

    [ mismatched, unregistered ]
  end

  def unmapped_program_names_message(mismatched, unregistered)
    "Refusing to drop corvid_case_programs.program_name: " \
      "#{mismatched} stored label(s) differ from the registry-derived name; " \
      "#{unregistered} program code(s) are not registered. " \
      "Export first, or set CORVID_DISCARD_PROGRAM_NAMES=1 to discard them and continue."
  end

  def backfill_program_names
    each_case_program_row do |row|
      row.update_columns(program_name: registry_program_name(row.program_code))
    end
  end

  def each_case_program_row
    CaseProgramRow.reset_column_information
    CaseProgramRow.find_each { |row| yield row }
  end

  # Same rule as Corvid::CaseProgram#program_name: stripped display_name, or
  # program_code when the entry is missing or the display name is blank.
  def registry_program_name(program_code)
    entry = Corvid::ProgramRegistry.find(program_code)
    entry&.display_name.to_s.strip.presence || program_code
  end
end
