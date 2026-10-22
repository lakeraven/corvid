# frozen_string_literal: true

# ADR 0003 says no corvid_* table contains patient names or dates of birth, and
# states the acceptance criterion that a corvid database dump must reveal no
# PHI. These two columns contradicted it in the schema of a PUBLIC repository,
# which is where anyone evaluating the claim reads it first.
#
# They were optional — `Case#cache_patient_data!` was the only writer and no
# host called it — but "no host currently elects to store PHI" is a different
# and much weaker claim than "the schema cannot hold it." The columns go.
#
# Offline display was the trade they bought. `Case#display_name` keeps its
# adapter lookup and its "Unknown Patient" fallback, so a host without vault
# access degrades to a placeholder instead of silently serving a cached name.
class DropCachedPatientPhiFromCorvidCases < ActiveRecord::Migration[8.1]
  def up
    remove_column :corvid_cases, :patient_name_cached
    remove_column :corvid_cases, :patient_dob_cached
  end

  # Deliberately irreversible. A `down` that re-adds columns for storing
  # patient names at rest is a migration whose whole purpose is to undo a
  # privacy guarantee; if it is ever genuinely wanted, it should be a new
  # decision with a new ADR, not a rollback.
  def down
    raise ActiveRecord::IrreversibleMigration,
      "Re-adding plaintext patient name/DOB columns needs a new decision, not a rollback (ADR 0003)"
  end
end
