# frozen_string_literal: true

require "test_helper"
require "rake"

# Pins corvid:verification_snapshots:scrub_legacy (lib/tasks/verification_snapshots.rake)
# for re-runnable legacy hash scrubbing after the one-shot migration.
class VerificationSnapshotsRakeTest < ActiveSupport::TestCase
  TENANT_ALPHA = "tnt_rake_scrub_alpha"
  TENANT_BETA = "tnt_rake_scrub_beta"
  KEYED_HASH = "a" * 64
  KEYED_VERSION = "v1-test"
  LEGACY_HASH = "d" * 64
  RAKE_PATH = Corvid::Engine.root.join("lib/tasks/verification_snapshots.rake").to_s
  TASK_NAME = "corvid:verification_snapshots:scrub_legacy"

  teardown do
    Corvid.reset_configuration!
  end

  def load_scrub_legacy_task!
    flunk "expected rake task at #{RAKE_PATH}" unless File.exist?(RAKE_PATH)

    load RAKE_PATH
    Rake::Task[TASK_NAME].reenable
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

  def invoke_scrub_legacy!
    out, err = capture_io { Rake::Task[TASK_NAME].invoke }
    Rake::Task[TASK_NAME].reenable
    [ out, err ]
  end

  test "scrub_legacy clears legacy verification_snapshot_hash in every tenant and leaves keyed rows unchanged" do
    load_scrub_legacy_task!

    legacy_alpha = nil
    legacy_beta = nil
    keyed = nil
    post_migration_legacy = nil

    with_tenant(TENANT_ALPHA) do
      legacy_alpha = create_legacy_row!(tenant: TENANT_ALPHA, person_identifier: "pt_legacy_alpha")
      keyed = create_keyed_row!(tenant: TENANT_ALPHA, person_identifier: "pt_keyed_alpha")
      post_migration_legacy = create_legacy_row!(
        tenant: TENANT_ALPHA,
        person_identifier: "pt_post_migration_legacy"
      )
    end

    with_tenant(TENANT_BETA) do
      legacy_beta = create_legacy_row!(tenant: TENANT_BETA, person_identifier: "pt_legacy_beta")
    end

    out, = invoke_scrub_legacy!

    legacy_alpha.reload
    legacy_beta.reload
    keyed.reload
    post_migration_legacy.reload

    assert_nil legacy_alpha.verification_snapshot_hash
    assert_nil legacy_beta.verification_snapshot_hash
    assert_nil post_migration_legacy.verification_snapshot_hash

    assert_equal KEYED_HASH, keyed.verification_snapshot_hash
    assert_equal KEYED_VERSION, keyed.verification_snapshot_key_version

    assert_match(/\A\d+\s*\z/, out.strip)
    refute_includes out, LEGACY_HASH
    refute_includes out, KEYED_HASH
    refute_includes out, "pt_legacy_alpha"
    refute_includes out, legacy_alpha.id.to_s
  end

  test "scrub_legacy is idempotent and prints only a count on each run" do
    load_scrub_legacy_task!

    with_tenant(TENANT_ALPHA) do
      create_legacy_row!(tenant: TENANT_ALPHA, person_identifier: "pt_idempotent")
    end

    first_out, = invoke_scrub_legacy!
    second_out, = invoke_scrub_legacy!

    assert_match(/\A\d+\s*\z/, first_out.strip)
    assert_match(/\A0\s*\z/, second_out.strip)
    refute_includes second_out, LEGACY_HASH
  end
end
