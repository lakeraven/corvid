# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "openssl"

class Corvid::SnapshotFingerprintTest < ActiveSupport::TestCase
  VERSION_V1 = "v1-test"
  VERSION_V2 = "v2-test"
  KEY_V1 = "test-snapshot-key-0001-xxxxxxxxxxxxxxxx"
  KEY_V2 = "test-snapshot-key-0002-yyyyyyyyyyyyyyyy"

  teardown do
    Corvid.reset_configuration!
  end

  test "compute returns HMAC-SHA256 hex digest and current key version" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    payload = { enrollment: { enrolled: true }, identity: {}, residency: {} }
    digest, version = Corvid::SnapshotFingerprint.compute(payload)

    expected = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate(payload))
    assert_equal expected, digest
    assert_equal VERSION_V1, version
  end

  test "compute digest differs from plain SHA256 of the same JSON payload" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    payload = { enrollment: { tribe_code: "DEMO" }, identity: { ssn_present: true }, residency: {} }
    digest, = Corvid::SnapshotFingerprint.compute(payload)
    plain = Digest::SHA256.hexdigest(JSON.generate(payload))

    refute_equal plain, digest
  end

  test "compute returns nil pair when no current key version is configured" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = nil
    end

    digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
    assert_nil digest
    assert_nil version
  end

  test "compute returns nil pair when current version key is missing from the keys hash" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = {}
      c.verification_snapshot_key_version = VERSION_V1
    end

    digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
    assert_nil digest
    assert_nil version
  end

  test "compute returns nil pair when current version key is shorter than 32 bytes" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => "too-short-key" }
      c.verification_snapshot_key_version = VERSION_V1
    end

    digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
    assert_nil digest
    assert_nil version
  end

  test "compute does not raise when configuration is incomplete" do
    Corvid.reset_configuration!
    assert_nothing_raised do
      Corvid::SnapshotFingerprint.compute({ any: "payload" })
    end
  end

  test "matches returns true when hash and version match the payload" do
    payload = { enrollment: { enrolled: false }, identity: {}, residency: {} }
    digest = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate(payload))

    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    assert Corvid::SnapshotFingerprint.matches?(hash: digest, version: VERSION_V1, payload: payload)
  end

  test "matches returns false when hash does not match the payload" do
    payload = { enrollment: { enrolled: true }, identity: {}, residency: {} }

    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    refute Corvid::SnapshotFingerprint.matches?(
      hash: "0" * 64,
      version: VERSION_V1,
      payload: payload
    )
  end

  test "matches returns nil for legacy rows with nil version" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: "a" * 64,
      version: nil,
      payload: { enrollment: {} }
    )
  end

  test "matches returns nil when row version key is not configured" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: "b" * 64,
      version: VERSION_V2,
      payload: { enrollment: {} }
    )
  end

  test "different configured key versions produce different digests for the same payload" do
    payload = { enrollment: { tribe_code: "DEMO" }, identity: {}, residency: {} }

    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1, VERSION_V2 => KEY_V2 }
      c.verification_snapshot_key_version = VERSION_V1
    end
    digest_v1, = Corvid::SnapshotFingerprint.compute(payload)

    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1, VERSION_V2 => KEY_V2 }
      c.verification_snapshot_key_version = VERSION_V2
    end
    digest_v2, = Corvid::SnapshotFingerprint.compute(payload)

    refute_equal digest_v1, digest_v2
  end
end
