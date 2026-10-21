# frozen_string_literal: true

module Corvid
  # Engine configuration. Hosts wire this in an initializer:
  #
  #   Corvid.configure do |c|
  #     c.adapter = Corvid::Adapters::FhirAdapter.new(base_url: ENV["FHIR_BASE_URL"])
  #     c.phi_sanitizer = ->(msg) { PhiSanitizer.redact(msg) }
  #     c.on_provenance = ->(**attrs) { Provenance.create!(**attrs) }
  #     c.fetch_provenance = ->(**attrs) { Provenance.where(**attrs).to_a }
  #   end
  #
  # Per ADR 0003, phi_sanitizer defaults to fail-safe redact-all so that
  # forgetting to configure it does not increase PHI exposure.
  class Configuration
    # Alternate-resource types whose check freshness is configurable (#640).
    # Duplicated so configuration can boot without loading app models.
    # test/corvid/configuration_test.rb keeps this aligned with
    # AlternateResourceCheck::RESOURCE_TYPES.
    ALTERNATE_RESOURCE_TYPES = %w[
      medicare_a medicare_b medicare_d medicaid va_benefits
      private_insurance workers_comp auto_insurance liability_coverage
      state_program tribal_program charity_care
    ].freeze

    attr_accessor :adapter, :edi_adapter, :phi_sanitizer, :on_provenance, :fetch_provenance

    def initialize
      @adapter = nil
      @edi_adapter = nil
      # Fail-safe redact-all default. Hosts MUST replace this with a real
      # sanitizer for human-readable error messages.
      @phi_sanitizer = ->(_msg) { "[REDACTED]" }
      @on_provenance = nil
      @fetch_provenance = ->(**) { [] }
    end

    # Frozen resource_type => Duration. Host overrides merge over the defaults.
    def alternate_resource_check_max_age
      overrides = max_age_overrides
      defaults = self.class.default_alternate_resource_check_max_age
      return defaults if overrides.empty?

      defaults.merge(overrides).freeze
    end

    def alternate_resource_check_max_age=(overrides)
      @alternate_resource_check_max_age_overrides = validated_max_ages(overrides)
    end

    # Max-age overrides are not part of the serialized configuration.
    def as_json(options = nil)
      super.except("alternate_resource_check_max_age_overrides")
    end

    def self.default_alternate_resource_check_max_age
      @default_alternate_resource_check_max_age ||= ALTERNATE_RESOURCE_TYPES.to_h { |type|
        [ type, type == "medicaid" ? 30.days : 90.days ]
      }.freeze
    end

    private

    def max_age_overrides
      return {} unless defined?(@alternate_resource_check_max_age_overrides)

      @alternate_resource_check_max_age_overrides
    end

    def validated_max_ages(overrides)
      overrides.each_value do |value|
        unless value.is_a?(ActiveSupport::Duration)
          raise ArgumentError, "alternate resource check max age must be a duration"
        end
        unless value.positive?
          raise ArgumentError, "alternate resource check max age must be positive"
        end
      end

      overrides.dup.freeze
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
