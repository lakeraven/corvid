# frozen_string_literal: true

require "corvid/version"
require "corvid/value_objects"
require "corvid/tenant_context"
require "corvid/configuration"
require "corvid/adapters/base"
require "corvid/adapters/mock_adapter"
require "corvid/adapters/fhir_adapter"

# When loaded inside a Rails app, also load the engine.
require "corvid/engine" if defined?(Rails::Engine)

module Corvid
  # Convenience accessors for tenant context.
  def self.current_tenant_identifier
    TenantContext.current_tenant_identifier
  end

  def self.current_tenant_identifier=(identifier)
    TenantContext.current_tenant_identifier = identifier
  end

  def self.current_facility_identifier
    TenantContext.current_facility_identifier
  end

  def self.current_facility_identifier=(identifier)
    TenantContext.current_facility_identifier = identifier
  end

  def self.with_tenant(identifier, &block)
    TenantContext.with_tenant(identifier, &block)
  end

  def self.require_tenant!
    TenantContext.require_tenant!
  end
end
