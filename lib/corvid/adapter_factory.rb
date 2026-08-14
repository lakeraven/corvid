# frozen_string_literal: true

require "corvid/adapters/mock_adapter"
require "corvid/adapters/fhir_adapter"

module Corvid
  # Builds an adapter instance from a resolved config + secret reader, per
  # ADR 0006 Decision 4 / issue #390.
  #
  # Built-in support covers the two adapter types that ship in public
  # corvid: "mock" and "fhir". The RPMS-shaped types from ADR 0006
  # ("rpms_direct", "rpms_connector") are NOT implemented here — those
  # adapters live in the private corvid-adapters repo alongside other
  # vendor adapters (see lib/corvid/adapters/base.rb). Hosts register
  # builders for them at boot:
  #
  #   Corvid::AdapterFactory.register("rpms_direct") do |config, secret_reader|
  #     RpmsDirectAdapter.new(host: config.endpoint,
  #                           access_code: secret_reader.fetch(config.secret_ref))
  #   end
  #
  # `config` is anything responding to #adapter_type, #endpoint, #secret_ref,
  # and #config (an extra kwargs hash) — in practice a
  # Corvid::TenantConnectionConfig record.
  module AdapterFactory
    class UnknownAdapterTypeError < StandardError; end

    BUILTIN_BUILDERS = {
      "mock" => ->(_config, _secret_reader) { Corvid::Adapters::MockAdapter.new },
      "fhir" => lambda do |config, secret_reader|
        extra = (config.config || {}).transform_keys(&:to_sym)
        Corvid::Adapters::FhirAdapter.new(
          base_url: config.endpoint,
          bearer_token: config.secret_ref ? secret_reader.fetch(config.secret_ref) : nil,
          **extra
        )
      end
    }.freeze

    class << self
      # Registers (or overrides) a builder for +adapter_type+. Builders are
      # process-global — call this once at boot (initializer), not per
      # request. Vendor adapters in private repos use this to plug in
      # without corvid knowing about them at all.
      def register(adapter_type, &builder)
        raise ArgumentError, "block required" unless builder

        registry[adapter_type.to_s] = builder
      end

      # Builds an adapter for +config+. Raises UnknownAdapterTypeError if no
      # builder is registered for config.adapter_type.
      def build(config, secret_reader: Corvid.configuration.secret_reader)
        builder = registry[config.adapter_type.to_s]
        unless builder
          raise UnknownAdapterTypeError,
                "no adapter builder registered for adapter_type #{config.adapter_type.inspect} " \
                "(known: #{registry.keys.sort.join(', ')}). Vendor adapters register via " \
                "Corvid::AdapterFactory.register(adapter_type) { |config, secret_reader| ... }."
        end

        builder.call(config, secret_reader)
      end

      # Test/boot helper: drops any host-registered builders, restoring the
      # built-in mock/fhir set only.
      def reset!
        @registry = BUILTIN_BUILDERS.dup
      end

      def registry
        @registry ||= BUILTIN_BUILDERS.dup
      end
    end
  end
end
