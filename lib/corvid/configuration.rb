# frozen_string_literal: true

module Corvid
  # Engine configuration. Hosts wire this in an initializer:
  #
  #   Corvid.configure do |c|
  #     c.adapter = Corvid::Adapters::FhirAdapter.new(base_url: ENV["FHIR_BASE_URL"])
  #     c.phi_sanitizer = ->(msg) { PhiSanitizer.redact(msg) }
  #     c.on_provenance = ->(**attrs) { Provenance.create!(**attrs) }
  #     c.fetch_provenance = ->(**attrs) { Provenance.where(**attrs).to_a }
  #     # HMAC keys for verification snapshot fingerprints (ADR 0008).
  #     # Hosts load these from a secret store. The database records only
  #     # the key version, never the key bytes.
  #     c.verification_snapshot_keys = {
  #       "2026-10" => secret_store.fetch("corvid/verification-snapshot/2026-10")
  #     }
  #     c.verification_snapshot_key_version = "2026-10"
  #   end
  #
  # Per ADR 0003, phi_sanitizer defaults to fail-safe redact-all so that
  # forgetting to configure it does not increase PHI exposure.
  #
  # #inspect lists verification snapshot key versions and does not reveal
  # key material. #as_json, #to_json, and #to_yaml emit those same redacted
  # fields and omit key bytes.
  class Configuration
    attr_accessor :adapter, :edi_adapter, :phi_sanitizer, :on_provenance, :fetch_provenance
    attr_accessor :verification_snapshot_keys, :verification_snapshot_key_version

    def initialize
      @adapter = nil
      @edi_adapter = nil
      # Fail-safe redact-all default. Hosts MUST replace this with a real
      # sanitizer for human-readable error messages.
      @phi_sanitizer = ->(_msg) { "[REDACTED]" }
      @on_provenance = nil
      @fetch_provenance = ->(**) { [] }
      @verification_snapshot_keys = {}
      @verification_snapshot_key_version = nil
    end

    def inspect
      "#<#{self.class.name} verification_snapshot_key_versions=#{snapshot_key_versions.inspect} " \
        "verification_snapshot_key_version=#{verification_snapshot_key_version.inspect}>"
    end

    def as_json(*)
      redacted_serialization
    end

    def to_json(*)
      as_json(*).to_json(*)
    end

    def encode_with(coder)
      redacted_serialization.each do |field, value|
        coder[field] = value
      end
    end

    private

    def redacted_serialization
      {
        "verification_snapshot_key_versions" => snapshot_key_versions,
        "verification_snapshot_key_version" => verification_snapshot_key_version
      }
    end

    def snapshot_key_versions
      keys = verification_snapshot_keys
      return [] unless keys.respond_to?(:keys)

      keys.keys
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    # Convenience accessors
    def adapter
      configuration.adapter
    end

    def edi_adapter
      configuration.edi_adapter
    end

    def sanitize_phi(message)
      configuration.phi_sanitizer.call(message)
    end
  end
end
