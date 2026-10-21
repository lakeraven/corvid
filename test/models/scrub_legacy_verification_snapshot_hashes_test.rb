# frozen_string_literal: true

require "test_helper"

class ScrubLegacyVerificationSnapshotHashesTest < ActiveSupport::TestCase
  TENANT_ALPHA = "tnt_scrub_alpha"
  TENANT_BETA = "tnt_scrub_beta"
  KEYED_HASH = "a" * 64
  KEYED_VERSION = "v1-test"
  LEGACY_HASH = "d" * 64

  teardown do
    Corvid.reset_configuration!
  end

  def scrub_migration_paths
    Dir[
      Rails.root.join("db/migrate/*_scrub_legacy_verification_snapshot_hashes.rb").to_s,
      Corvid::Engine.root.join("db/migrate/*_scrub_legacy_verification_snapshot_hashes.rb").to_s
    ]
  end

  def require_scrub_migration!
    paths = scrub_migration_paths
    flunk "expected migration file matching *_scrub_legacy_verification_snapshot_hashes.rb" if paths.empty?

    path = paths.first
    require path unless defined?(ScrubLegacyVerificationSnapshotHashes)
    path
  end

  def create_legacy_row!(tenant:, person_identifier:)
    row = Corvid::PrcEligibilityDecision.create!(
      tenant_identifier: tenant,
      person_identifier: person_identifier,
      facility_identifier: "fac_demo",
      decided_at: Time.current,
      as_of_date: Date.current,
      eligible: false,
      reason_codes: [ "not_enrolled" ]
    )
    row.update_columns(
      verification_snapshot_hash: LEGACY_HASH,
      verification_snapshot_key_version: nil
    )
    row
  end

  def create_keyed_row!(tenant:, person_identifier:)
    Corvid::PrcEligibilityDecision.create!(
      tenant_identifier: tenant,
      person_identifier: person_identifier,
      facility_identifier: "fac_demo",
      decided_at: Time.current,
      as_of_date: Date.current,
      eligible: true,
      reason_codes: [],
      verification_snapshot_hash: KEYED_HASH,
      verification_snapshot_key_version: KEYED_VERSION
    )
  end

  test "migrate up nulls legacy verification_snapshot_hash in every tenant and leaves keyed rows unchanged" do
    require_scrub_migration!

    legacy_alpha = nil
    legacy_beta = nil
    keyed = nil

    with_tenant(TENANT_ALPHA) do
      legacy_alpha = create_legacy_row!(tenant: TENANT_ALPHA, person_identifier: "pt_legacy_alpha")
      keyed = create_keyed_row!(tenant: TENANT_ALPHA, person_identifier: "pt_keyed_alpha")
    end

    with_tenant(TENANT_BETA) do
      legacy_beta = create_legacy_row!(tenant: TENANT_BETA, person_identifier: "pt_legacy_beta")
    end

    ActiveRecord::Migration.suppress_messages do
      ScrubLegacyVerificationSnapshotHashes.new.migrate(:up)
    end

    legacy_alpha.reload
    legacy_beta.reload
    keyed.reload

    assert_nil legacy_alpha.verification_snapshot_hash
    assert_nil legacy_alpha.verification_snapshot_key_version

    assert_nil legacy_beta.verification_snapshot_hash
    assert_nil legacy_beta.verification_snapshot_key_version

    assert_equal KEYED_HASH, keyed.verification_snapshot_hash
    assert_equal KEYED_VERSION, keyed.verification_snapshot_key_version
  end

  # Owner decision: the scrub cannot be undone, so down is a documented no-op
  # rather than raising. It must not restore or touch any hash.
  test "migrate down is a no-op that restores nothing" do
    require_scrub_migration!

    scrubbed = nil
    keyed = nil
    with_tenant(TENANT_ALPHA) do
      scrubbed = create_legacy_row!(tenant: TENANT_ALPHA, person_identifier: "pt_scrubbed_down")
      keyed = create_keyed_row!(tenant: TENANT_ALPHA, person_identifier: "pt_keyed_down")
    end

    ActiveRecord::Migration.suppress_messages do
      ScrubLegacyVerificationSnapshotHashes.new.migrate(:up)
    end

    assert_nothing_raised do
      ActiveRecord::Migration.suppress_messages do
        ScrubLegacyVerificationSnapshotHashes.new.migrate(:down)
      end
    end

    assert_nil scrubbed.reload.verification_snapshot_hash
    assert_nil scrubbed.verification_snapshot_key_version
    assert_equal KEYED_HASH, keyed.reload.verification_snapshot_hash
    assert_equal KEYED_VERSION, keyed.verification_snapshot_key_version
  end

  test "migrate up leaves rows with no hash unchanged" do
    require_scrub_migration!

    blank = nil
    with_tenant(TENANT_ALPHA) do
      blank = Corvid::PrcEligibilityDecision.create!(
        tenant_identifier: TENANT_ALPHA,
        person_identifier: "pt_no_hash",
        facility_identifier: "fac_demo",
        decided_at: Time.current,
        as_of_date: Date.current,
        eligible: false,
        reason_codes: [ "not_enrolled" ]
      )
    end

    ActiveRecord::Migration.suppress_messages do
      ScrubLegacyVerificationSnapshotHashes.new.migrate(:up)
    end

    assert_nil blank.reload.verification_snapshot_hash
    assert_nil blank.verification_snapshot_key_version
  end
end
