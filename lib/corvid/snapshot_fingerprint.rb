# frozen_string_literal: true

require "json"
require "openssl"
require "time"

module Corvid
  # HMAC-SHA256 fingerprint of an eligibility verification snapshot (ADR 0008).
  #
  # The key comes from Corvid.configuration, which hosts load from a secret
  # store. A plain SHA256 is never produced. The HMAC input is canonical JSON.
  # A usable version is a String or Symbol, non-blank after strip, at most
  # MAX_VERSION_LENGTH characters. When no usable key is configured, or the
  # digest cannot be computed, compute returns [nil, nil] so callers persist
  # no fingerprint.
  module SnapshotFingerprint
    MIN_KEY_BYTES = 32
    MAX_VERSION_LENGTH = 64

    class << self
      # Returns [hex_digest, key_version], or [nil, nil] when no usable key
      # is configured or the digest cannot be computed. key_version is the
      # configured version as a String.
      def compute(payload)
        version = normalized_version(Corvid.configuration.verification_snapshot_key_version)
        key = usable_key(version)
        return [ nil, nil ] if key.nil?

        begin
          [ hex_digest(key, payload), version ]
        rescue StandardError => error
          log_fingerprint_failure(error)
          [ nil, nil ]
        end
      end

      # True or false when the row's key version can be checked. nil when
      # the version is blank, that key is missing or invalid, or the digest
      # cannot be computed (legacy and unknown versions are unverifiable,
      # not mismatches).
      def matches?(hash:, version:, payload:)
        key = usable_key(version)
        return nil if key.nil?
        return false unless hash.is_a?(String)

        secure_equal?(hash, hex_digest(key, payload))
      rescue StandardError
        nil
      end

      private

      def usable_key(version)
        name = normalized_version(version)
        return if name.nil?

        key = key_named(name)
        key if key.is_a?(String) && key.bytesize >= MIN_KEY_BYTES
      rescue StandardError
        nil
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
          string_keyed[key.to_s] = canonicalize(nested)
        end
        string_keyed.sort.to_h
      end

      def canonical_leaf(value)
        return canonical_time(value) if time_like?(value)
        return value.iso8601 if date_like?(value)

        value
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

      def log_fingerprint_failure(error)
        return unless defined?(Rails)
        return unless Rails.respond_to?(:logger)

        Rails.logger&.warn(fingerprint_failure_message(error))
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
