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

  # ---- Issue #629 gate round 2 (failing until implemented) ------------------

  test "compute finds symbol-keyed snapshot key when configured version is String" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { :"v1-test" => KEY_V1 }
      c.verification_snapshot_key_version = "v1-test"
    end

    payload = { enrollment: { enrolled: true }, identity: {}, residency: {} }
    digest, version = Corvid::SnapshotFingerprint.compute(payload)

    expected = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate(payload))
    assert_equal expected, digest
    assert_equal "v1-test", version
  end

  test "compute with symbol version matches digest from string-keyed keys and returns String version" do
    payload = { enrollment: { tribe_code: "DEMO" }, identity: {}, residency: {} }

    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test" => KEY_V1 }
      c.verification_snapshot_key_version = "v1-test"
    end
    digest_from_string_version, = Corvid::SnapshotFingerprint.compute(payload)

    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test" => KEY_V1 }
      c.verification_snapshot_key_version = :"v1-test"
    end
    digest, version = Corvid::SnapshotFingerprint.compute(payload)

    assert_equal digest_from_string_version, digest
    assert_equal "v1-test", version
  end

  test "matches verifies digest when keys hash is keyed by Symbol" do
    payload = { enrollment: { enrolled: false }, identity: {}, residency: {} }

    Corvid.configure do |c|
      c.verification_snapshot_keys = { :"v1-test" => KEY_V1 }
      c.verification_snapshot_key_version = "v1-test"
    end
    digest, = Corvid::SnapshotFingerprint.compute(payload)

    Corvid.configure do |c|
      c.verification_snapshot_keys = { :"v1-test" => KEY_V1 }
    end

    assert Corvid::SnapshotFingerprint.matches?(hash: digest, version: "v1-test", payload: payload)
  end

  test "compute returns nil pair when configured version is not String or Symbol" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { 2026 => KEY_V1, "2026" => KEY_V1 }
      c.verification_snapshot_key_version = 2026
    end

    digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
    assert_nil digest
    assert_nil version
  end

  test "matches returns nil when version is not String or Symbol" do
    payload = { enrollment: { enrolled: true }, identity: {}, residency: {} }
    digest = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate(payload))

    Corvid.configure do |c|
      c.verification_snapshot_keys = { 2026 => KEY_V1 }
    end

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: 2026,
      payload: payload
    )
  end

  test "compute returns nil pair when configured version exceeds 64 characters" do
    long_version = "v" * 65
    Corvid.configure do |c|
      c.verification_snapshot_keys = { long_version => KEY_V1 }
      c.verification_snapshot_key_version = long_version
    end

    digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
    assert_nil digest
    assert_nil version
  end

  test "matches does not use Hash default for missing version keys" do
    payload = { enrollment: { enrolled: true }, identity: {}, residency: {} }
    keys_with_default = Hash.new(KEY_V1).merge("v1-test" => KEY_V1)

    Corvid.configure do |c|
      c.verification_snapshot_keys = keys_with_default
      c.verification_snapshot_key_version = "v1-test"
    end
    digest, = Corvid::SnapshotFingerprint.compute(payload)

    Corvid.configure do |c|
      c.verification_snapshot_keys = keys_with_default
    end

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: "retired",
      payload: payload
    )
  end

  test "compute returns nil pair for version missing from keys even when Hash has default key" do
    keys_with_default = Hash.new(KEY_V1).merge("v1-test" => KEY_V1)

    Corvid.configure do |c|
      c.verification_snapshot_keys = keys_with_default
      c.verification_snapshot_key_version = "retired"
    end

    digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
    assert_nil digest
    assert_nil version
  end

  test "compute digest is independent of top-level Hash key order" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    digest_ab, = Corvid::SnapshotFingerprint.compute({ a: 1, b: 2 })
    digest_ba, = Corvid::SnapshotFingerprint.compute({ b: 2, a: 1 })

    assert_equal digest_ab, digest_ba
  end

  test "compute digest is independent of nested Hash key order" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    nested_ab = { outer: { a: 1, b: 2 } }
    nested_ba = { outer: { b: 2, a: 1 } }

    digest_ab, = Corvid::SnapshotFingerprint.compute(nested_ab)
    digest_ba, = Corvid::SnapshotFingerprint.compute(nested_ba)

    assert_equal digest_ab, digest_ba
  end

  test "compute digest treats symbol and string keys as equivalent" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    payload_symbol_keys = { enrollment: { tribe_code: "DEMO" }, identity: {}, residency: {} }
    payload_string_keys = { "enrollment" => { "tribe_code" => "DEMO" }, "identity" => {}, "residency" => {} }

    digest_symbol, = Corvid::SnapshotFingerprint.compute(payload_symbol_keys)
    digest_string, = Corvid::SnapshotFingerprint.compute(payload_string_keys)

    assert_equal digest_symbol, digest_string
  end

  test "compute digest treats TimeWithZone for same instant equally across zones" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    instant = Time.utc(2026, 5, 16, 12, 0, 0.123456)

    digest_utc = nil
    Time.use_zone("UTC") do
      digest_utc, = Corvid::SnapshotFingerprint.compute({ verified_at: instant.in_time_zone })
    end

    digest_honolulu = nil
    Time.use_zone("Pacific/Honolulu") do
      digest_honolulu, = Corvid::SnapshotFingerprint.compute({ verified_at: instant.in_time_zone })
    end

    assert_equal digest_utc, digest_honolulu
  end

  test "compute returns nil pair and logs snapshot warning without payload values for unserializable payload" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    log_io = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log_io)

    sentinel = "SENTINEL-VALUE-NOT-IN-LOG"
    payload = { enrollment: { value: Float::NAN }, marker: sentinel }

    digest, version = nil
    assert_nothing_raised do
      digest, version = Corvid::SnapshotFingerprint.compute(payload)
    end

    Rails.logger = original_logger

    assert_nil digest
    assert_nil version
    log_message = log_io.string
    assert_includes log_message.downcase, "snapshot"
    refute_includes log_message, sentinel
  end

  test "matches returns nil for unserializable payload" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    digest = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate({ ok: true }))

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: VERSION_V1,
      payload: { enrollment: { value: Float::NAN } }
    )
  end
end
