# frozen_string_literal: true

module Corvid
  # Engine configuration. Hosts wire this in an initializer:
  #
  #   Corvid.configure do |c|
  #     c.adapter = Corvid::Adapters::FhirAdapter.new(base_url: ENV["FHIR_BASE_URL"])
  #     c.phi_sanitizer = ->(msg) { PhiSanitizer.redact(msg) }
  #     c.on_provenance = ->(**attrs) { Provenance.create!(**attrs) }
  #     c.fetch_provenance = ->(**attrs) { Provenance.where(**attrs).to_a }
  #     c.secret_reader = MyVaultReader.new # default: Corvid::SecretReader::Env
  #     c.adapter_router_cache_ttl = 60 # seconds; used by Corvid::AdapterRouter
  #   end
  #
  # Per ADR 0003, phi_sanitizer defaults to fail-safe redact-all so that
  # forgetting to configure it does not increase PHI exposure.
  #
  # `adapter` remains the static single-adapter path (unchanged, still the
  # default nearly every model and service reads via Corvid.adapter).
  # `secret_reader` and `adapter_router_cache_ttl` back the newer per-tenant
  # path: Corvid::AdapterRouter.resolve(tenant_id) / Corvid.resolve_adapter,
  # per ADR 0006 Decision 4 / issue #390. Introducing the router does not
  # remove or change `adapter` — see AdapterRouter's module doc for the
  # fallback relationship between the two.
  class Configuration
    attr_accessor :adapter, :edi_adapter, :phi_sanitizer, :on_provenance, :fetch_provenance,
                  :secret_reader, :adapter_router_cache_ttl

    def initialize
      @adapter = nil
      @edi_adapter = nil
      # Fail-safe redact-all default. Hosts MUST replace this with a real
      # sanitizer for human-readable error messages.
      @phi_sanitizer = ->(_msg) { "[REDACTED]" }
      @on_provenance = nil
      @fetch_provenance = ->(**) { [] }
      # ENV-backed default; production multi-tenant hosts plug Vault / AWS
      # Secrets Manager / etc. per ADR 0006 Decision 3.
      @secret_reader = Corvid::SecretReader::Env.new
      @adapter_router_cache_ttl = 60
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
