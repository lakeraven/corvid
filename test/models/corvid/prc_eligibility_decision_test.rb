# frozen_string_literal: true

require "test_helper"

class Corvid::PrcEligibilityDecisionTest < ActiveSupport::TestCase
  TENANT = "tnt_test"

  teardown do
    Corvid.reset_configuration!
  end

  test "requires verification_snapshot_key_version when verification_snapshot_hash is present" do
    with_tenant(TENANT) do
      row = Corvid::PrcEligibilityDecision.new(
        tenant_identifier: TENANT,
        person_identifier: "pt_val",
        facility_identifier: "fac_demo",
        decided_at: Time.current,
        as_of_date: Date.current,
        eligible: true,
        reason_codes: [],
        verification_snapshot_hash: "c" * 64,
        verification_snapshot_key_version: nil
      )

      refute row.valid?
      assert_includes row.errors[:verification_snapshot_key_version], "can't be blank"
    end
  end

  test "legacy row with hash and nil key version still loads and is readable" do
    with_tenant(TENANT) do
      row = Corvid::PrcEligibilityDecision.create!(
        tenant_identifier: TENANT,
        person_identifier: "pt_legacy",
        facility_identifier: "fac_demo",
        decided_at: Time.current,
        as_of_date: Date.current,
        eligible: false,
        reason_codes: [ "not_enrolled" ]
      )

      legacy_hash = "d" * 64
      row.update_columns(
        verification_snapshot_hash: legacy_hash,
        verification_snapshot_key_version: nil
      )

      reloaded = Corvid::PrcEligibilityDecision.find(row.id)
      assert_equal legacy_hash, reloaded.verification_snapshot_hash
      assert_nil reloaded.verification_snapshot_key_version
      assert_equal "pt_legacy", reloaded.person_identifier
    end
  end
end
