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
      c.verification_snapshot_keys = { "v1-test": KEY_V1 }
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
      c.verification_snapshot_keys = { "v1-test": KEY_V1 }
      c.verification_snapshot_key_version = "v1-test"
    end
    digest, = Corvid::SnapshotFingerprint.compute(payload)

    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test": KEY_V1 }
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

  # ---- Issue #629 gate round 3 (failing until implemented) ------------------

  def capture_snapshot_fingerprint_logs
    log_io = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log_io)
    yield log_io
  ensure
    Rails.logger = original_logger
  end

  test "compute logs snapshot warning when configured version key is missing from keys hash" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = {}
      c.verification_snapshot_key_version = VERSION_V1
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, KEY_V1
      refute_includes log_message, VERSION_V1
    end
  end

  test "compute logs snapshot warning when configured version key is shorter than 32 bytes" do
    short_key = "too-short-key"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => short_key }
      c.verification_snapshot_key_version = VERSION_V1
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, short_key
      refute_includes log_message, VERSION_V1
    end
  end

  test "compute logs snapshot warning when configured version has trailing newline" do
    version_with_newline = "#{VERSION_V1}\n"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = version_with_newline
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, KEY_V1
      refute_includes log_message, version_with_newline
    end
  end

  test "compute logs snapshot warning when configured version exceeds 64 characters" do
    long_version = "v" * 65
    Corvid.configure do |c|
      c.verification_snapshot_keys = { long_version => KEY_V1 }
      c.verification_snapshot_key_version = long_version
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, KEY_V1
      refute_includes log_message, long_version
    end
  end

  test "compute logs nothing when no key version is configured and keys are empty" do
    Corvid.reset_configuration!

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version
      assert_empty log_io.string
    end
  end

  test "compute returns nil pair for single-byte zero key material of 32 bytes" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => "\0" * 32 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, VERSION_V1
    end
  end

  test "compute returns nil pair for single-byte ascii zero key material of 32 bytes" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => "0" * 32 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, VERSION_V1
    end
  end

  test "compute returns nil pair for single-byte space key material of 32 bytes" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => " " * 32 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, VERSION_V1
    end
  end

  test "matches returns nil when key material is a single repeated byte of length 32" do
    payload = { enrollment: { enrolled: true }, identity: {}, residency: {} }
    repeated_key = "0" * 32

    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => repeated_key }
    end

    digest = OpenSSL::HMAC.hexdigest("SHA256", repeated_key, JSON.generate(payload))

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: VERSION_V1,
      payload: payload
    )
  end

  test "compute returns nil pair and logs snapshot warning for Object leaf in payload" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ enrollment: Object.new })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
    end
  end

  test "compute returns nil pair and logs snapshot warning for Struct leaf in payload" do
    snapshot_struct = Struct.new(:marker)
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ enrollment: snapshot_struct.new("x") })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
    end
  end

  test "matches returns nil for Object leaf in payload" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    digest = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate({ ok: true }))

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: VERSION_V1,
      payload: { enrollment: Object.new }
    )
  end

  test "compute returns nil pair for hash keys that collide after stringification" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    digest, version = Corvid::SnapshotFingerprint.compute({ a: 1, "a" => 2 })
    assert_nil digest
    assert_nil version
  end

  test "matches returns nil for hash keys that collide after stringification" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    digest = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate({ canonical: true }))

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: VERSION_V1,
      payload: { a: 1, "a" => 2 }
    )
  end

  # ---- Issue #629 gate round 4 (failing until implemented) ------------------

  test "compute returns nil pair for configured version with invalid UTF-8 encoding" do
    bad_version = "\xFFv1".dup.force_encoding("UTF-8")
    Corvid.configure do |c|
      c.verification_snapshot_keys = { bad_version => KEY_V1 }
      c.verification_snapshot_key_version = bad_version
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest = version = nil
      begin
        digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      rescue StandardError => error
        flunk "expected compute not to raise, got #{error.class}"
      end
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_match(/snapshot/i, log_message)
      refute_includes log_message, KEY_V1
    end
  end

  test "compute returns nil pair for configured version containing null control character" do
    version_with_nul = "#{VERSION_V1}\0"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { version_with_nul => KEY_V1 }
      c.verification_snapshot_key_version = version_with_nul
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = nil
      assert_nothing_raised do
        digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      end
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, KEY_V1
      refute_includes log_message, version_with_nul
    end
  end

  test "compute returns nil pair for configured version containing tab control character" do
    version_with_tab = "#{VERSION_V1}\t"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { version_with_tab => KEY_V1 }
      c.verification_snapshot_key_version = version_with_tab
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = nil
      assert_nothing_raised do
        digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      end
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, KEY_V1
    end
  end

  test "matches returns nil when version string contains a control character" do
    version_with_nul = "#{VERSION_V1}\0"
    payload = { enrollment: { enrolled: true }, identity: {}, residency: {} }

    Corvid.configure do |c|
      c.verification_snapshot_keys = { version_with_nul => KEY_V1 }
    end

    digest = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate(payload))

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: version_with_nul,
      payload: payload
    )
  end

  test "matches returns nil when hash is nil and version is usable" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: nil,
      version: VERSION_V1,
      payload: { enrollment: {} }
    )
  end

  test "matches returns nil when hash is empty string and version is usable" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
    end

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: "",
      version: VERSION_V1,
      payload: { enrollment: {} }
    )
  end

  test "compute returns nil pair when symbol and string keys collide after to_s" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test": KEY_V1, "v1-test" => KEY_V2 }
      c.verification_snapshot_key_version = "v1-test"
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil version

      log_message = log_io.string
      assert_includes log_message.downcase, "snapshot"
      refute_includes log_message, KEY_V1
      refute_includes log_message, KEY_V2
    end
  end

  test "matches returns nil when symbol and string version keys collide after to_s" do
    payload = { enrollment: { enrolled: true }, identity: {}, residency: {} }

    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test": KEY_V1, "v1-test" => KEY_V2 }
    end

    digest = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate(payload))

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: "v1-test",
      payload: payload
    )
  end

  # ---- Issue #629 maintainer decisions (failing until implemented) ----------

  def enrollment_payload_with_verified_at(verified_at)
    {
      enrollment: { tribe_code: "DEMO", member_status: "enrolled", verified_at: verified_at },
      identity: { ssn_present: true, dob_present: false, birthplace_present: false },
      residency: { on_reservation: true, address: "1 Example Road", verified_at: verified_at }
    }
  end

  test "compute digest ignores verified_at at enrollment and residency when times differ" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test": KEY_V1 }
      c.verification_snapshot_key_version = "v1-test"
    end

    t1 = Time.utc(2026, 5, 16, 12, 0, 0)
    t2 = Time.utc(2027, 8, 1, 9, 30, 45)

    digest_t1, = Corvid::SnapshotFingerprint.compute(enrollment_payload_with_verified_at(t1))
    digest_t2, = Corvid::SnapshotFingerprint.compute(enrollment_payload_with_verified_at(t2))

    assert_equal digest_t1, digest_t2
  end

  test "compute digest ignores nested verified_at with string or symbol keys" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    t1 = Time.utc(2026, 1, 1, 0, 0, 0)
    t2 = Time.utc(2026, 12, 31, 23, 59, 59)

    with_symbol = {
      enrollment: { tribe_code: "DEMO", audit: { verified_at: t1 } },
      identity: {},
      residency: {}
    }
    with_string = {
      "enrollment" => { "tribe_code" => "DEMO", "audit" => { "verified_at" => t2 } },
      "identity" => {},
      "residency" => {}
    }

    digest_symbol, = Corvid::SnapshotFingerprint.compute(with_symbol)
    digest_string, = Corvid::SnapshotFingerprint.compute(with_string)

    assert_equal digest_symbol, digest_string
  end

  test "compute digest changes when a non verified_at field changes" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { VERSION_V1 => KEY_V1 }
      c.verification_snapshot_key_version = VERSION_V1
    end

    verified_at = Time.utc(2026, 5, 16, 12, 0, 0)
    base = enrollment_payload_with_verified_at(verified_at)
    changed = base.merge(
      enrollment: base[:enrollment].merge(tribe_code: "OTHER")
    )

    digest_base, = Corvid::SnapshotFingerprint.compute(base)
    digest_changed, = Corvid::SnapshotFingerprint.compute(changed)

    refute_equal digest_base, digest_changed
  end

  test "matches returns true when payloads differ only by verified_at" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test": KEY_V1 }
      c.verification_snapshot_key_version = "v1-test"
    end

    t1 = Time.utc(2026, 5, 16, 12, 0, 0)
    t2 = Time.utc(2026, 5, 17, 15, 0, 0)
    payload_t1 = enrollment_payload_with_verified_at(t1)
    payload_t2 = enrollment_payload_with_verified_at(t2)

    digest, version = Corvid::SnapshotFingerprint.compute(payload_t1)

    assert Corvid::SnapshotFingerprint.matches?(
      hash: digest,
      version: version,
      payload: payload_t2
    )
  end

  test "compute returns nil pair for ideographic-space-only key version with matching key" do
    version = "\u3000"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { version => KEY_V1 }
      c.verification_snapshot_key_version = version
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, returned_version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil returned_version
      assert_includes log_io.string, Corvid::SnapshotFingerprint::UNUSABLE_KEY_MESSAGE
    end
  end

  test "compute returns nil pair for no-break-space-only key version with matching key" do
    version = "\u00a0"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { version => KEY_V1 }
      c.verification_snapshot_key_version = version
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, returned_version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil returned_version
      assert_includes log_io.string, Corvid::SnapshotFingerprint::UNUSABLE_KEY_MESSAGE
    end
  end

  test "compute returns nil pair for em-space-only key version with matching key" do
    version = "\u2003"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { version => KEY_V1 }
      c.verification_snapshot_key_version = version
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, returned_version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil returned_version
      assert_includes log_io.string, Corvid::SnapshotFingerprint::UNUSABLE_KEY_MESSAGE
    end
  end

  test "compute returns nil pair for key version that is only a format character" do
    version = "\u200e"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { version => KEY_V1 }
      c.verification_snapshot_key_version = version
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, returned_version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil returned_version
      assert_includes log_io.string, Corvid::SnapshotFingerprint::UNUSABLE_KEY_MESSAGE
    end
  end

  test "compute returns nil pair for key version containing zero-width space suffix" do
    version_with_zwsp = "#{VERSION_V1}\u200b"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { version_with_zwsp => KEY_V1 }
      c.verification_snapshot_key_version = version_with_zwsp
    end

    capture_snapshot_fingerprint_logs do |log_io|
      digest, returned_version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest
      assert_nil returned_version
      assert_includes log_io.string, Corvid::SnapshotFingerprint::UNUSABLE_KEY_MESSAGE
    end
  end

  test "matches returns nil when version contains zero-width space format character" do
    version_with_zwsp = "v1-test\u200b"
    payload = { enrollment: { tribe_code: "DEMO" }, identity: {}, residency: {} }

    Corvid.configure do |c|
      c.verification_snapshot_keys = { version_with_zwsp => KEY_V1 }
    end

    assert_nil Corvid::SnapshotFingerprint.matches?(
      hash: "f" * 64,
      version: version_with_zwsp,
      payload: payload
    )
  end

  # ---- Issue #629 chair round 2 (failing until implemented) -----------------

  UNUSABLE_PRINTABLE_ASCII_VERSIONS = [
    [ "hangul filler", "\u3164" ],
    [ "hangul choseong filler", "\u115F" ],
    [ "halfwidth hangul filler", "\uFFA0" ],
    [ "braille blank", "\u2800" ],
    [ "musical symbol null notehead", "\u1D159" ],
    [ "non-ascii letter suffix", "v1-\u00e9" ],
    [ "inner ascii space", "v1 test" ]
  ].freeze

  USABLE_PRINTABLE_ASCII_VERSIONS = [
    "v1-test",
    "2026-10",
    "dummy-v1"
  ].freeze

  UNUSABLE_PRINTABLE_ASCII_VERSIONS.each do |label, version|
    test "compute returns nil pair for #{label} key version" do
      Corvid.configure do |c|
        c.verification_snapshot_keys = { version => KEY_V1 }
        c.verification_snapshot_key_version = version
      end

      digest, returned_version = Corvid::SnapshotFingerprint.compute({ sample: true })
      assert_nil digest, "expected unusable version #{label}"
      assert_nil returned_version
    end

    test "matches returns nil for #{label} key version" do
      payload = { enrollment: { tribe_code: "DEMO" }, identity: {}, residency: {} }

      Corvid.configure do |c|
        c.verification_snapshot_keys = { version => KEY_V1 }
      end

      digest = OpenSSL::HMAC.hexdigest("SHA256", KEY_V1, JSON.generate(payload))

      assert_nil Corvid::SnapshotFingerprint.matches?(
        hash: digest,
        version: version,
        payload: payload
      )
    end
  end

  USABLE_PRINTABLE_ASCII_VERSIONS.each do |version|
    test "compute accepts printable ascii key version #{version}" do
      Corvid.configure do |c|
        c.verification_snapshot_keys = { version => KEY_V1 }
        c.verification_snapshot_key_version = version
      end

      digest, returned_version = Corvid::SnapshotFingerprint.compute({ sample: true })
      refute_nil digest
      assert_equal version, returned_version
    end
  end

  test "compute accepts symbol printable ascii key version" do
    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test" => KEY_V1 }
      c.verification_snapshot_key_version = :"v1-test"
    end

    digest, returned_version = Corvid::SnapshotFingerprint.compute({ sample: true })
    refute_nil digest
    assert_equal "v1-test", returned_version
  end
end
