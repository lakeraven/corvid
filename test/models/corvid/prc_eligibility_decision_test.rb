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

  test "legacy row with hash and nil key version can be updated through validations" do
    with_tenant(TENANT) do
      row = Corvid::PrcEligibilityDecision.create!(
        tenant_identifier: TENANT,
        person_identifier: "pt_legacy_upd",
        facility_identifier: "fac_demo",
        decided_at: Time.current,
        as_of_date: Date.current,
        eligible: false,
        reason_codes: [ "not_enrolled" ]
      )

      row.update_columns(
        verification_snapshot_hash: "d" * 64,
        verification_snapshot_key_version: nil
      )

      row.reload
      row.update!(decided_by_identifier: "usr_demo")

      reloaded = Corvid::PrcEligibilityDecision.find(row.id)
      assert_equal "usr_demo", reloaded.decided_by_identifier
      assert_equal "d" * 64, reloaded.verification_snapshot_hash
      assert_nil reloaded.verification_snapshot_key_version
    end
  end

  test "legacy row rejects assigning a new hash without key version" do
    with_tenant(TENANT) do
      row = Corvid::PrcEligibilityDecision.create!(
        tenant_identifier: TENANT,
        person_identifier: "pt_legacy_newhash",
        facility_identifier: "fac_demo",
        decided_at: Time.current,
        as_of_date: Date.current,
        eligible: false,
        reason_codes: [ "not_enrolled" ]
      )

      row.update_columns(
        verification_snapshot_hash: "d" * 64,
        verification_snapshot_key_version: nil
      )

      row.reload
      row.verification_snapshot_hash = "f" * 64
      row.verification_snapshot_key_version = nil

      refute row.valid?
      assert_includes row.errors[:verification_snapshot_key_version], "can't be blank"
    end
  end

  # ---- Issue #629 gate round 3 (failing until implemented) ------------------

  test "legacy row rejects verification_snapshot_key_version change without verification_snapshot_hash change" do
    with_tenant(TENANT) do
      row = Corvid::PrcEligibilityDecision.create!(
        tenant_identifier: TENANT,
        person_identifier: "pt_legacy_version_only",
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

      row.reload
      refute row.update(verification_snapshot_key_version: "v1-test")
      assert row.errors[:verification_snapshot_key_version].present?
    end
  end
end
