# frozen_string_literal: true

# ADR 0008: verification snapshots are HMAC-SHA256 under a host-supplied
# key. The key stays out of the database; the row records which key version
# produced the digest so a later check can still verify after rotation.
# Nullable so legacy plain-SHA256 rows (hash present, version nil) keep loading.
class AddVerificationSnapshotKeyVersionToCorvidPrcEligibilityDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :corvid_prc_eligibility_decisions, :verification_snapshot_key_version, :string
  end
end
