# frozen_string_literal: true

require "json"
require "openssl"
require "time"

module Corvid
  # HMAC-SHA256 fingerprint of an eligibility verification snapshot (ADR 0008).
  #
  # The key comes from Corvid.configuration, which hosts load from a secret
  # store. A plain SHA256 is never produced. The HMAC input is canonical JSON
  # of the allowed leaf types. A usable version is a String or Symbol,
  # non-blank after strip, at most MAX_VERSION_LENGTH characters. A usable
  # key is a String of at least MIN_KEY_BYTES whose bytes are not all the
  # same byte. When the configured version is non-nil and no usable key
  # backs it, compute logs a warning and returns [nil, nil]. A nil version
  # logs nothing. When the digest cannot be computed, compute returns
  # [nil, nil] so callers persist no fingerprint.
  module SnapshotFingerprint
    MIN_KEY_BYTES = 32
    MAX_VERSION_LENGTH = 64
    UNUSABLE_KEY_MESSAGE =
      "corvid.snapshot_fingerprint: verification snapshot key version is configured but has no usable key"

    # Payload leaf or hash key that cannot be canonicalized. The message is
    # the class name only, so a log of the class never includes payload values.
    class CanonicalizationError < StandardError; end

    class << self
      # Returns [hex_digest, key_version], or [nil, nil] when no usable key
      # is configured or the digest cannot be computed. key_version is the
      # configured version as a String. A non-nil version with no usable key
      # logs a warning that omits the key and the version.
      def compute(payload)
        configured = Corvid.configuration.verification_snapshot_key_version
        version = normalized_version(configured)
        key = usable_key(version)
        return unavailable_fingerprint(configured) if key.nil?

        begin
          [ hex_digest(key, payload), version ]
        rescue StandardError => error
          log_fingerprint_failure(error)
          [ nil, nil ]
        end
      end

      # True or false when the row's key version can be checked. nil when
      # the version is blank, that key is missing or invalid (including a
      # repeated-byte key), or the digest cannot be computed (legacy and
      # unknown versions are unverifiable, not mismatches).
      def matches?(hash:, version:, payload:)
        key = usable_key(version)
        return nil if key.nil?
        return false unless hash.is_a?(String)

        secure_equal?(hash, hex_digest(key, payload))
      rescue StandardError
        nil
      end

      private

      def unavailable_fingerprint(configured)
        log_unusable_configured_key unless configured.nil?
        [ nil, nil ]
      end

      def usable_key(version)
        name = normalized_version(version)
        return if name.nil?

        key = key_named(name)
        return unless usable_key_material?(key)

        key
      rescue StandardError
        nil
      end

      def usable_key_material?(key)
        key.is_a?(String) && key.bytesize >= MIN_KEY_BYTES && !repeated_byte_key?(key)
      end

      # Every byte equal to the first byte, including a run of a single ASCII
      # character. Empty strings never reach this check.
      def repeated_byte_key?(key)
        sample = key.getbyte(0)
        key.each_byte.all? { |byte| byte == sample }
      end

      def normalized_version(version)
        return unless version.is_a?(String) || version.is_a?(Symbol)

        name = version.to_s
        return if name.strip.empty? || name.length > MAX_VERSION_LENGTH

        name
      end

      # Pair walk: Hash#[] would follow a default value or default proc.
      def key_named(name)
        keys = Corvid.configuration.verification_snapshot_keys
        return unless keys.respond_to?(:each_pair)

        keys.each_pair do |candidate, material|
          return material if candidate.to_s == name
        end

        nil
      end

      def hex_digest(key, payload)
        OpenSSL::HMAC.hexdigest("SHA256", key, canonical_json(payload))
      end

      def canonical_json(payload)
        JSON.generate(canonicalize(payload))
      end

      def canonicalize(value)
        case value
        when Hash
          canonical_hash(value)
        when Array
          value.map { |entry| canonicalize(entry) }
        else
          canonical_leaf(value)
        end
      end

      def canonical_hash(hash)
        string_keyed = {}
        hash.each_pair do |key, nested|
          name = key.to_s
          raise CanonicalizationError if string_keyed.key?(name)

          string_keyed[name] = canonicalize(nested)
        end
        string_keyed.sort.to_h
      end

      # String, Symbol (to_s), Integer, Float, true, false, and nil.
      # Time-like values and Date are handled first. NaN and Infinity stay
      # Floats so JSON.generate rejects them.
      def canonical_leaf(value)
        return canonical_time(value) if time_like?(value)
        return value.iso8601 if date_like?(value)
        return value.to_s if value.is_a?(Symbol)
        return value if json_primitive?(value)

        raise CanonicalizationError
      end

      def json_primitive?(value)
        return true if [ nil, true, false ].include?(value)

        value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float)
      end

      def canonical_time(value)
        time = value.respond_to?(:to_time) ? value.to_time : value
        time.dup.utc.iso8601(6)
      end

      def time_like?(value)
        value.is_a?(Time) || date_time?(value) || time_with_zone?(value)
      end

      def date_time?(value)
        defined?(DateTime) && value.is_a?(DateTime)
      end

      def time_with_zone?(value)
        defined?(ActiveSupport::TimeWithZone) && value.is_a?(ActiveSupport::TimeWithZone)
      end

      def date_like?(value)
        defined?(Date) && value.is_a?(Date) && !time_like?(value)
      end

      def log_unusable_configured_key
        log_warning(UNUSABLE_KEY_MESSAGE)
      end

      def log_fingerprint_failure(error)
        log_warning(fingerprint_failure_message(error))
      end

      def log_warning(message)
        return unless defined?(Rails)
        return unless Rails.respond_to?(:logger)

        Rails.logger&.warn(message)
      rescue StandardError
        nil
      end

      def fingerprint_failure_message(error)
        "corvid.snapshot_fingerprint: could not compute verification snapshot fingerprint (#{error.class})"
      end

      def secure_equal?(left, right)
        return false unless left.is_a?(String) && right.is_a?(String)
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end
    end
  end
end
