# frozen_string_literal: true

module Corvid
  # Engine configuration. Hosts wire this in an initializer:
  #
  #   Corvid.configure do |c|
  #     # FHIR_BASE_URL must be path-qualified, for example
  #     # https://fhir.vendor.example/r4. Bearer tokens and search next
  #     # links are scoped to that base path.
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
  #
  # payer_authorization_turnarounds maps payer_identifier to a positive
  # ActiveSupport::Duration (default {}). Keys are stored as strings.
  # The writer rejects a non-Hash, a blank key, a non-duration, and a
  # duration that is not positive. It is not secret. It is omitted from
  # inspect/as_json/to_yaml with the other operational settings so those
  # methods stay an allow-list of snapshot key versions.
  class Configuration
    # Alternate-resource types whose check freshness is configurable (#640).
    # Duplicated so configuration can boot without loading app models.
    # test/models/corvid/alternate_resource_check_test.rb keeps this aligned with
    # AlternateResourceCheck::RESOURCE_TYPES.
    ALTERNATE_RESOURCE_TYPES = %w[
      medicare_a medicare_b medicare_d medicaid va_benefits
      private_insurance workers_comp auto_insurance liability_coverage
      state_program tribal_program charity_care
    ].freeze

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
      @payer_authorization_turnarounds = {}.freeze
    end

    def payer_authorization_turnarounds
      @payer_authorization_turnarounds
    end

    def payer_authorization_turnarounds=(turnarounds)
      @payer_authorization_turnarounds = validated_payer_authorization_turnarounds(turnarounds)
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

    # Frozen resource_type => Duration. Host overrides merge over the defaults.
    # Override keys are stored as strings and must be alternate resource types.
    def alternate_resource_check_max_age
      overrides = max_age_overrides
      defaults = self.class.default_alternate_resource_check_max_age
      return defaults if overrides.empty?

      defaults.merge(overrides).freeze
    end

    def alternate_resource_check_max_age=(overrides)
      @alternate_resource_check_max_age_overrides = validated_max_ages(overrides)
    end

    def self.default_alternate_resource_check_max_age
      @default_alternate_resource_check_max_age ||= ALTERNATE_RESOURCE_TYPES.to_h { |type|
        [ type, type == "medicaid" ? 30.days : 90.days ]
      }.freeze
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

    def max_age_overrides
      return {} unless defined?(@alternate_resource_check_max_age_overrides)

      @alternate_resource_check_max_age_overrides
    end

    # Symbol keys become strings. Blank keys, non-durations, and
    # non-positive durations are rejected. Anything other than a Hash
    # is rejected before the pairs are read.
    def validated_payer_authorization_turnarounds(turnarounds)
      unless turnarounds.is_a?(Hash)
        raise ArgumentError, "payer authorization turnarounds must be a hash"
      end

      turnarounds.to_h { |key, value|
        payer = key.to_s
        if payer.strip.empty?
          raise ArgumentError, "payer authorization turnaround payer identifier can't be blank"
        end
        unless value.is_a?(ActiveSupport::Duration)
          raise ArgumentError, "payer authorization turnaround must be a duration"
        end
        unless value.positive?
          raise ArgumentError, "payer authorization turnaround must be positive"
        end

        [ payer, value ]
      }.freeze
    end

    # Symbol keys become strings. Unknown types, non-durations, and
    # non-positive durations are rejected.
    def validated_max_ages(overrides)
      overrides.to_h { |key, value|
        type = key.to_s
        unless ALTERNATE_RESOURCE_TYPES.include?(type)
          raise ArgumentError, "unknown alternate resource type: #{type}"
        end
        unless value.is_a?(ActiveSupport::Duration)
          raise ArgumentError, "alternate resource check max age must be a duration"
        end
        unless value.positive?
          raise ArgumentError, "alternate resource check max age must be positive"
        end

        [ type, value ]
      }.freeze
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
