# frozen_string_literal: true

# Legacy unkeyed digests are dictionary-attackable (ADR 0003/0008) and
# cannot be re-keyed because inputs are not retained.
class ScrubLegacyVerificationSnapshotHashes < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE corvid_prc_eligibility_decisions
      SET verification_snapshot_hash = NULL
      WHERE verification_snapshot_key_version IS NULL
        AND verification_snapshot_hash IS NOT NULL
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "legacy unkeyed verification snapshot hashes cannot be restored"
  end
end
