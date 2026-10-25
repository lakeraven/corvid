# frozen_string_literal: true

# #591 classified corvid_case_programs.program_name as patient PHI. The column
# is also redundant: program_code is NOT NULL, unique per case, and validated
# against Corvid::ProgramRegistry, which owns the display name.
#
# up drops the column only when every stored label equals one of the three
# historical forms for its code and every program_code is registered. A label
# counts as drifted only when it equals none of them. The forms are computed
# from the registry entry, with nil-safe access when the entry or its display
# name is missing:
# - stripped rule (Corvid::CaseProgram#program_name, and down):
#   display_name.to_s.strip.presence || program_code
# - presence rule (ProgramTemplateService on main):
#   display_name.presence || program_code
# - raw rule (migration 20260506000001):
#   display_name || program_code
# Otherwise up raises UnmappedProgramNames with the drifted-label count and
# the unregistered-code count and nothing else (ADR 0003 — no labels, codes,
# or ids). Export the labels first, or set CORVID_DISCARD_PROGRAM_NAMES=1 to
# drop the column anyway.
#
# down re-adds a nullable string, backfills each row with the stripped rule
# only, then sets NOT NULL. The scan and the backfill use a migration-local
# model, not Corvid::CaseProgram, so they do not depend on the app model's
# tenant scope or its derived reader.
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
      mismatched += 1 if drifted_program_name?(row)
      unregistered += 1 unless Corvid::ProgramRegistry.exists?(row.program_code)
    end

    [ mismatched, unregistered ]
  end

  # Equals none of the stripped, presence, and raw forms for this code.
  def drifted_program_name?(row)
    historical_program_names(row.program_code).exclude?(row.program_name)
  end

  def unmapped_program_names_message(mismatched, unregistered)
    "Refusing to drop corvid_case_programs.program_name: " \
      "#{mismatched} stored label(s) match none of the historical forms for their code; " \
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

  # Stripped display_name, or program_code when the entry is missing or the
  # display name is blank. Same rule as Corvid::CaseProgram#program_name.
  # down backfills with this rule only.
  def registry_program_name(program_code)
    entry = Corvid::ProgramRegistry.find(program_code)
    stripped_program_name(entry&.display_name, program_code)
  end

  def historical_program_names(program_code)
    entry = Corvid::ProgramRegistry.find(program_code)
    display_name = entry&.display_name

    [
      stripped_program_name(display_name, program_code),
      presence_program_name(display_name, program_code),
      raw_program_name(display_name, program_code)
    ]
  end

  def stripped_program_name(display_name, program_code)
    display_name.to_s.strip.presence || program_code
  end

  # ProgramTemplateService on main. Blank names fall back; others are kept
  # without stripping.
  def presence_program_name(display_name, program_code)
    display_name&.presence || program_code
  end

  # Migration 20260506000001. Only nil falls back, so a blank or
  # whitespace-only display name is kept.
  def raw_program_name(display_name, program_code)
    display_name || program_code
  end
end
