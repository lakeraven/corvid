# frozen_string_literal: true

require "json"
require "openssl"

module Corvid
  # HMAC-SHA256 fingerprint of an eligibility verification snapshot (ADR 0008).
  #
  # The key comes from Corvid.configuration, which hosts load from a secret
  # store. A plain SHA256 is never produced. When the current version is
  # blank, or the key is missing, not a String, or shorter than MIN_KEY_BYTES,
  # compute returns [nil, nil] so callers persist no fingerprint.
  module SnapshotFingerprint
    MIN_KEY_BYTES = 32

    class << self
      # Returns [hex_digest, key_version], or [nil, nil] when no usable key
      # is configured.
      def compute(payload)
        version = configured_version
        key = usable_key(version)
        return [ nil, nil ] if key.nil?

        [ OpenSSL::HMAC.hexdigest("SHA256", key, JSON.generate(payload)), version ]
      rescue StandardError
        [ nil, nil ]
      end

      # True or false when the row's key version can be checked. nil when
      # the version is blank or that key is missing or invalid (legacy and
      # unknown versions are unverifiable, not mismatches).
      def matches?(hash:, version:, payload:)
        key = usable_key(version)
        return nil if key.nil?
        return false unless hash.is_a?(String)

        expected = OpenSSL::HMAC.hexdigest("SHA256", key, JSON.generate(payload))
        secure_equal?(hash, expected)
      rescue StandardError
        false
      end

      private

      def configured_version
        version = Corvid.configuration.verification_snapshot_key_version
        return if blank_version?(version)

        version
      end

      def usable_key(version)
        return if blank_version?(version)

        keys = Corvid.configuration.verification_snapshot_keys
        return unless keys.respond_to?(:[])

        key = keys[version]
        key if key.is_a?(String) && key.bytesize >= MIN_KEY_BYTES
      rescue StandardError
        nil
      end

      def blank_version?(version)
        return true if version.nil? || version == false
        return true if version.is_a?(String) && version.strip.empty?

        false
      end

      def secure_equal?(left, right)
        return false unless left.is_a?(String) && right.is_a?(String)
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end
    end
  end
end
