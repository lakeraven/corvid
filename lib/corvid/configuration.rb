# frozen_string_literal: true

require "date"

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

    # Dates an eligibility response uses for "no real end". verify! stores
    # those coverage_end and renewal_date values as nil (open) only when
    # this is an Array. 9999-12-31 is always open. Default includes that
    # sentinel (#712).
    attr_accessor :placeholder_coverage_end_dates

    # A coverage_end or renewal_date more than this many years after the
    # inquiry date is a placeholder and is stored as nil. With no inquiry
    # date the horizon is measured from Time.current. A value that is not
    # a positive Integer falls back to 25 (#712).
    attr_accessor :placeholder_coverage_end_horizon_years

    # Extra resource types whose current_for? is limited to the year-month
    # of inquiry_date_of_service, compared case-insensitively. Medicaid is
    # always month-bounded. Nil or a non-Array adds nothing. A saved check
    # with no inquiry date is not current (#712).
    attr_accessor :month_bounded_eligibility_resource_types

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
      @placeholder_coverage_end_dates = [ Date.new(9999, 12, 31) ]
      @placeholder_coverage_end_horizon_years = 25
      @month_bounded_eligibility_resource_types = %w[medicaid]
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
