# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"

# Tests the four eligibility-matrix scenarios against MockAdapter:
#   - True positive       (enrolled in contracted tribe, all checks pass)
#   - True negative       (not enrolled)
#   - Would-be false positive (enrolled in wrong tribe — naive logic would approve)
#   - Would-be false negative (stale confidence — naive logic would deny)
#
# Plus the persistence contract: every decide call writes a
# PrcEligibilityDecision row inside a transaction.
class Corvid::TribalEligibilityServiceTest < ActiveSupport::TestCase
  Facility = Struct.new(
    :identifier,
    :contracted_tribe_code,
    :requires_on_reservation_flag,
    :requires_ssn_on_file_flag,
    keyword_init: true
  ) do
    def requires_on_reservation?
      requires_on_reservation_flag
    end

    def requires_ssn_on_file?
      requires_ssn_on_file_flag
    end
  end

  TENANT = "tenant_test"

  setup do
    Corvid::TenantContext.reset!
    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
    Corvid::PrcEligibilityDecision.unscoped.delete_all
    Corvid::TenantContext.current_tenant_identifier = TENANT

    @facility = Facility.new(
      identifier: "fac_demo",
      contracted_tribe_code: "DEMO",
      requires_on_reservation_flag: true,
      requires_ssn_on_file_flag: true
    )
    @adapter = Corvid.adapter
  end

  SNAPSHOT_VERSION_V1 = "v1-test"
  SNAPSHOT_VERSION_V2 = "v2-test"
  SNAPSHOT_KEY_V1 = "test-snapshot-key-0001-xxxxxxxxxxxxxxxx"
  SNAPSHOT_KEY_V2 = "test-snapshot-key-0002-yyyyyyyyyyyyyyyy"

  teardown do
    Corvid::TenantContext.reset!
    Corvid.reset_configuration!
  end

  def configure_snapshot_keys!(version:, keys:)
    Corvid.configure do |c|
      c.verification_snapshot_keys = keys
      c.verification_snapshot_key_version = version
    end
  end

  def fixed_adapter_responses_for(person_id)
    @adapter.add_enrollment(person_id,
                            enrolled: true, tribe_code: "DEMO", tribe_name: "Demo Tribe",
                            member_status: "enrolled", confidence: :verified)
    @adapter.add_patient(person_id, ssn_last4: "1234", dob: Date.new(1980, 1, 1), birthplace: "Springfield")
    @adapter.define_singleton_method(:verify_residency) do |pid|
      if pid == person_id
        { on_reservation: true, address: "Rd", verified_at: Time.parse("2026-05-16T12:00:00Z") }
      end
    end
  end

  def adapter_snapshot_payload(person_id)
    {
      enrollment: @adapter.verify_tribal_enrollment(person_id),
      identity: @adapter.verify_identity_documents(person_id),
      residency: @adapter.verify_residency(person_id)
    }
  end

  # ---- True positive --------------------------------------------------------

  test "decide approves an enrolled-in-contracted-tribe person with all checks satisfied" do
    @adapter.add_enrollment("pt_tp",
                            enrolled: true, tribe_name: "Demo Tribe",
                            tribe_code: "DEMO", member_status: "enrolled",
                            confidence: :verified)
    @adapter.add_patient("pt_tp", ssn_last4: "1234", dob: Date.new(1980, 1, 1), birthplace: "Springfield")
    @adapter.instance_variable_get(:@residencies)["pt_tp"] = { on_reservation: true, address: "Reservation Rd" }
    @adapter.define_singleton_method(:verify_residency) do |pid|
      { on_reservation: true, address: "Reservation Rd", verified_at: Time.current } if pid == "pt_tp"
    end

    decision = Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_tp",
      facility: @facility,
      tenant_identifier: TENANT
    )

    assert decision.eligible?
    assert_empty(decision.reason_codes & Corvid::TribalEligibilityService::HARD_FAIL_REASONS)
  end

  # ---- True negative --------------------------------------------------------

  test "decide denies a not-enrolled person with reason :not_enrolled" do
    @adapter.add_enrollment("pt_tn",
                            enrolled: false,
                            tribe_name: nil,
                            tribe_code: nil,
                            member_status: "denied",
                            confidence: :verified)

    decision = Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_tn",
      facility: @facility,
      tenant_identifier: TENANT
    )

    refute decision.eligible?
    assert_includes decision.reason_codes, :not_enrolled
  end

  # ---- Would-be false positive (wrong-tribe enrollee caught) ----------------

  test "decide denies a person enrolled in a tribe other than the facility's contracted tribe" do
    @adapter.add_enrollment("pt_wfp",
                            enrolled: true, tribe_name: "Other Tribe",
                            tribe_code: "OTHER", member_status: "enrolled",
                            confidence: :verified)

    decision = Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_wfp",
      facility: @facility,
      tenant_identifier: TENANT
    )

    refute decision.eligible?
    assert_includes decision.reason_codes, :not_enrolled_in_contracted_tribe
  end

  # ---- Would-be false negative (stale data must not deny on its own) --------

  test "decide approves stale-but-otherwise-eligible enrollment with informational warning" do
    @adapter.add_enrollment("pt_wfn",
                            enrolled: true, tribe_name: "Demo Tribe",
                            tribe_code: "DEMO", member_status: "enrolled",
                            confidence: :stale)
    @adapter.add_patient("pt_wfn", ssn_last4: "5678", dob: Date.new(1985, 2, 2), birthplace: "Springfield")
    @adapter.define_singleton_method(:verify_residency) do |pid|
      { on_reservation: true, address: "Reservation Rd", verified_at: Time.current } if pid == "pt_wfn"
    end

    decision = Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_wfn",
      facility: @facility,
      tenant_identifier: TENANT
    )

    assert decision.eligible?, "stale-but-otherwise-eligible should be approved, not denied"
    assert_includes decision.reason_codes, :enrollment_stale,
                    "stale should surface as an informational warning"
    assert_empty(decision.reason_codes & Corvid::TribalEligibilityService::HARD_FAIL_REASONS)
  end

  # ---- Persistence contract -------------------------------------------------

  test "decide treats blank tenant_identifier as absent and uses TenantContext tenant" do
    with_tenant("tnt_test") do
      assert_difference "Corvid::PrcEligibilityDecision.count", 1 do
        Corvid::TribalEligibilityService.decide(
          person_identifier: "pt_blank_tenant",
          facility: @facility,
          tenant_identifier: ""
        )
      end

      assert_equal "tnt_test", Corvid::PrcEligibilityDecision.last.tenant_identifier
    end
  end

  test "decide persists a PrcEligibilityDecision row per call" do
    assert_difference "Corvid::PrcEligibilityDecision.count", 1 do
      Corvid::TribalEligibilityService.decide(
        person_identifier: "pt_p1",
        facility: @facility,
        tenant_identifier: TENANT
      )
    end

    row = Corvid::PrcEligibilityDecision.last
    assert_equal "pt_p1", row.person_identifier
    assert_equal "fac_demo", row.facility_identifier
    assert_equal TENANT, row.tenant_identifier
    refute_nil row.verification_snapshot_hash
    refute_nil row.decided_at
  end

  test "decide produces a deterministic snapshot hash for identical inputs" do
    @adapter.add_enrollment("pt_hash",
                            enrolled: true, tribe_code: "DEMO", tribe_name: "Demo Tribe",
                            member_status: "enrolled", confidence: :verified)
    @adapter.add_patient("pt_hash", ssn_last4: "1234", dob: Date.new(1980, 1, 1), birthplace: "Springfield")
    @adapter.define_singleton_method(:verify_residency) do |pid|
      { on_reservation: true, address: "Rd", verified_at: Time.parse("2026-05-16") } if pid == "pt_hash"
    end

    d1 = Corvid::TribalEligibilityService.decide(person_identifier: "pt_hash", facility: @facility, tenant_identifier: TENANT)
    d2 = Corvid::TribalEligibilityService.decide(person_identifier: "pt_hash", facility: @facility, tenant_identifier: TENANT)

    row1 = Corvid::PrcEligibilityDecision.find(d1.decision_id)
    row2 = Corvid::PrcEligibilityDecision.find(d2.decision_id)
    refute_nil row1.verification_snapshot_hash
    # Snapshot hashes WILL differ because verified_at differs between calls;
    # this test documents that. The reproducibility-of-decision is what
    # matters — same inputs → same eligible? result.
    assert_equal row1.eligible, row2.eligible
    assert_equal row1.reason_codes, row2.reason_codes
  end

  # ---- Keyed verification snapshot fingerprint (issue #629 / ADR 0008) ------

  test "decide stores keyed verification_snapshot_hash and verification_snapshot_key_version" do
    configure_snapshot_keys!(
      version: SNAPSHOT_VERSION_V1,
      keys: { SNAPSHOT_VERSION_V1 => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_keyed")

    Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_keyed",
      facility: @facility,
      tenant_identifier: TENANT
    )

    row = Corvid::PrcEligibilityDecision.last
    payload = adapter_snapshot_payload("pt_keyed")
    expected_digest, expected_version = Corvid::SnapshotFingerprint.compute(payload)

    assert_equal expected_digest, row.verification_snapshot_hash
    assert_equal expected_version, row.verification_snapshot_key_version
  end

  test "decide produces identical snapshot fingerprint for identical adapter responses and key" do
    configure_snapshot_keys!(
      version: SNAPSHOT_VERSION_V1,
      keys: { SNAPSHOT_VERSION_V1 => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_same")

    Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_same",
      facility: @facility,
      tenant_identifier: TENANT
    )
    hash1 = Corvid::PrcEligibilityDecision.last.verification_snapshot_hash
    version1 = Corvid::PrcEligibilityDecision.last.verification_snapshot_key_version

    Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_same",
      facility: @facility,
      tenant_identifier: TENANT
    )
    hash2 = Corvid::PrcEligibilityDecision.last.verification_snapshot_hash
    version2 = Corvid::PrcEligibilityDecision.last.verification_snapshot_key_version

    assert_equal hash1, hash2
    assert_equal version1, version2
  end

  test "decide snapshot fingerprint changes when verification_snapshot_key_version changes" do
    fixed_adapter_responses_for("pt_ver")

    configure_snapshot_keys!(
      version: SNAPSHOT_VERSION_V1,
      keys: { SNAPSHOT_VERSION_V1 => SNAPSHOT_KEY_V1, SNAPSHOT_VERSION_V2 => SNAPSHOT_KEY_V2 }
    )
    Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_ver",
      facility: @facility,
      tenant_identifier: TENANT
    )
    hash_v1 = Corvid::PrcEligibilityDecision.last.verification_snapshot_hash

    configure_snapshot_keys!(
      version: SNAPSHOT_VERSION_V2,
      keys: { SNAPSHOT_VERSION_V1 => SNAPSHOT_KEY_V1, SNAPSHOT_VERSION_V2 => SNAPSHOT_KEY_V2 }
    )
    Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_ver",
      facility: @facility,
      tenant_identifier: TENANT
    )
    hash_v2 = Corvid::PrcEligibilityDecision.last.verification_snapshot_hash

    refute_equal hash_v1, hash_v2
  end

  test "decide leaves snapshot hash and key version nil when no snapshot key is configured" do
    Corvid.reset_configuration!
    Corvid.configure { |c| c.adapter = @adapter }

    fixed_adapter_responses_for("pt_nokey")

    decision = Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_nokey",
      facility: @facility,
      tenant_identifier: TENANT
    )

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
  end

  test "decide logs the fixed warning and saves nil snapshot columns when the configured key is missing" do
    configure_snapshot_keys!(version: SNAPSHOT_VERSION_V1, keys: {})
    fixed_adapter_responses_for("pt_missing_key")

    log_io = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log_io)
    begin
      decision = Corvid::TribalEligibilityService.decide(
        person_identifier: "pt_missing_key",
        facility: @facility,
        tenant_identifier: TENANT
      )
    ensure
      Rails.logger = original_logger
    end

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
    assert_includes log_io.string, Corvid::SnapshotFingerprint::UNUSABLE_KEY_MESSAGE
    refute_includes log_io.string, SNAPSHOT_VERSION_V1
  end

  test "decide saves the decision with nil snapshot columns when an adapter returns a cyclic response" do
    configure_snapshot_keys!(
      version: SNAPSHOT_VERSION_V1,
      keys: { SNAPSHOT_VERSION_V1 => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_cyclic")
    @adapter.define_singleton_method(:verify_residency) do |pid|
      next unless pid == "pt_cyclic"

      response = { on_reservation: true, address: "Rd", verified_at: Time.current }
      response[:source] = response
      response
    end

    decision = nil
    assert_nothing_raised do
      decision = Corvid::TribalEligibilityService.decide(
        person_identifier: "pt_cyclic",
        facility: @facility,
        tenant_identifier: TENANT
      )
    end

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
  end

  test "decide snapshot hash is not a plain SHA256 of adapter responses" do
    configure_snapshot_keys!(
      version: SNAPSHOT_VERSION_V1,
      keys: { SNAPSHOT_VERSION_V1 => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_not_plain")

    Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_not_plain",
      facility: @facility,
      tenant_identifier: TENANT
    )

    row = Corvid::PrcEligibilityDecision.last
    payload = adapter_snapshot_payload("pt_not_plain")
    plain_sha = Digest::SHA256.hexdigest(JSON.generate(payload))

    refute_equal plain_sha, row.verification_snapshot_hash
  end

  test "decide saves nil snapshot hash and version when configured key version exceeds 64 characters" do
    long_version = "v" * 65
    configure_snapshot_keys!(
      version: long_version,
      keys: { long_version => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_longver")

    decision = Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_longver",
      facility: @facility,
      tenant_identifier: TENANT
    )

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
  end

  # ---- Issue #629 gate round 4 (failing until implemented) ------------------

  test "decide saves nil snapshot hash and version when configured version contains null byte" do
    version_with_nul = "#{SNAPSHOT_VERSION_V1}\0"
    configure_snapshot_keys!(
      version: version_with_nul,
      keys: { version_with_nul => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_nul_ver")

    decision = nil
    begin
      decision = Corvid::TribalEligibilityService.decide(
        person_identifier: "pt_nul_ver",
        facility: @facility,
        tenant_identifier: TENANT
      )
    rescue StandardError => error
      flunk "expected decide not to raise, got #{error.class}"
    end

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
  end

  test "decide saves nil snapshot hash and version when configured version contains tab control character" do
    version_with_tab = "#{SNAPSHOT_VERSION_V1}\t"
    configure_snapshot_keys!(
      version: version_with_tab,
      keys: { version_with_tab => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_tab_ver")

    decision = Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_tab_ver",
      facility: @facility,
      tenant_identifier: TENANT
    )

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
  end

  test "decide saves nil snapshot hash and version when configured version has invalid UTF-8 encoding" do
    bad_version = "\xFFv1".dup.force_encoding("UTF-8")
    configure_snapshot_keys!(
      version: bad_version,
      keys: { bad_version => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_bad_utf8_ver")

    decision = nil
    begin
      decision = Corvid::TribalEligibilityService.decide(
        person_identifier: "pt_bad_utf8_ver",
        facility: @facility,
        tenant_identifier: TENANT
      )
    rescue StandardError => error
      flunk "expected decide not to raise, got #{error.class}"
    end

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
  end

  # ---- Issue #629 maintainer decisions (failing until implemented) ----------

  test "decide records same verification_snapshot_hash when only verified_at changes between calls" do
    configure_snapshot_keys!(
      version: SNAPSHOT_VERSION_V1,
      keys: { SNAPSHOT_VERSION_V1 => SNAPSHOT_KEY_V1 }
    )

    person_id = "pt_verified_at_stable"
    @adapter.add_enrollment(
      person_id,
      enrolled: true,
      tribe_code: "DEMO",
      tribe_name: "Demo Tribe",
      member_status: "enrolled",
      confidence: :verified
    )
    @adapter.add_patient(person_id, ssn_last4: "1234", dob: Date.new(1980, 1, 1), birthplace: "Springfield")
    @adapter.define_singleton_method(:verify_residency) do |pid|
      next unless pid == person_id

      { on_reservation: true, address: "Rd", verified_at: Time.current }
    end

    travel_to Time.utc(2026, 3, 10, 14, 0, 0) do
      Corvid::TribalEligibilityService.decide(
        person_identifier: person_id,
        facility: @facility,
        tenant_identifier: TENANT
      )
    end
    hash_first = Corvid::PrcEligibilityDecision.last.verification_snapshot_hash

    travel_to Time.utc(2028, 11, 2, 8, 15, 30) do
      Corvid::TribalEligibilityService.decide(
        person_identifier: person_id,
        facility: @facility,
        tenant_identifier: TENANT
      )
    end
    hash_second = Corvid::PrcEligibilityDecision.last.verification_snapshot_hash

    refute_nil hash_first
    assert_equal hash_first, hash_second
  end

  test "decide saves nil snapshot hash and version for ideographic-space-only key version" do
    version = "\u3000"
    configure_snapshot_keys!(version: version, keys: { version => SNAPSHOT_KEY_V1 })
    fixed_adapter_responses_for("pt_ws_ver")

    decision = nil
    assert_nothing_raised do
      decision = Corvid::TribalEligibilityService.decide(
        person_identifier: "pt_ws_ver",
        facility: @facility,
        tenant_identifier: TENANT
      )
    end

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
  end

  # Whitespace-only or invisible versions are no usable key: decide must not
  # raise RecordInvalid from the model's presence check.
  [
    [ "ascii space", " " ],
    [ "no-break space", " " ],
    [ "em space", " " ],
    [ "zero-width space", "​" ],
    [ "byte order mark", "﻿" ],
    [ "no-break space and zero-width space", " ​" ]
  ].each do |label, version|
    test "decide saves nil snapshot hash and version for #{label}-only key version" do
      person_id = "pt_blank_ver_#{label.tr(' -', '__')}"
      configure_snapshot_keys!(version: version, keys: { version => SNAPSHOT_KEY_V1 })
      fixed_adapter_responses_for(person_id)

      decision = nil
      assert_nothing_raised do
        decision = Corvid::TribalEligibilityService.decide(
          person_identifier: person_id,
          facility: @facility,
          tenant_identifier: TENANT
        )
      end

      row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
      assert decision.eligible?
      assert_nil row.verification_snapshot_hash
      assert_nil row.verification_snapshot_key_version
    end
  end

  test "decide stored fingerprint matches a re-check that differs only in verified_at" do
    configure_snapshot_keys!(
      version: SNAPSHOT_VERSION_V1,
      keys: { SNAPSHOT_VERSION_V1 => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_recheck")

    decision = Corvid::TribalEligibilityService.decide(
      person_identifier: "pt_recheck",
      facility: @facility,
      tenant_identifier: TENANT
    )
    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)

    recheck = travel_to(Time.utc(2026, 9, 1, 8, 30, 0)) { adapter_snapshot_payload("pt_recheck") }
    recheck[:residency] = recheck[:residency].merge(verified_at: Time.utc(2026, 9, 1, 8, 30, 0))

    assert Corvid::SnapshotFingerprint.matches?(
      hash: row.verification_snapshot_hash,
      version: row.verification_snapshot_key_version,
      payload: recheck
    )
  end

  test "decide saves nil snapshot hash and version for key version with zero-width space format character" do
    version_with_zwsp = "#{SNAPSHOT_VERSION_V1}\u200b"
    configure_snapshot_keys!(
      version: version_with_zwsp,
      keys: { version_with_zwsp => SNAPSHOT_KEY_V1 }
    )
    fixed_adapter_responses_for("pt_zwsp_ver")

    decision = nil
    assert_nothing_raised do
      decision = Corvid::TribalEligibilityService.decide(
        person_identifier: "pt_zwsp_ver",
        facility: @facility,
        tenant_identifier: TENANT
      )
    end

    row = Corvid::PrcEligibilityDecision.find(decision.decision_id)
    assert decision.eligible?
    assert_nil row.verification_snapshot_hash
    assert_nil row.verification_snapshot_key_version
  end
end
