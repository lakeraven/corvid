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
