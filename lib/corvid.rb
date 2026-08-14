# frozen_string_literal: true

require "corvid/version"
require "corvid/value_objects"
require "corvid/tenant_context"
require "corvid/secret_reader"
require "corvid/configuration"
require "corvid/program_registry"
require "corvid/adapters/base"
require "corvid/adapters/mock_adapter"
require "corvid/adapters/fhir_adapter"
require "corvid/adapter_factory"
require "corvid/adapter_router"

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

  # Per-tenant adapter resolution (ADR 0006 Decision 4 / #390). Prefer this
  # over the bare `Corvid.adapter` global at any call site that needs to be
  # tenant-aware (new code, and existing call sites as they're migrated).
  # Falls back to `Corvid.adapter` when the tenant has no
  # TenantConnectionConfig row, so single-tenant hosts need no changes.
  def self.resolve_adapter(tenant_identifier, facility_identifier: nil, force: false)
    AdapterRouter.resolve(tenant_identifier, facility_identifier: facility_identifier, force: force)
  end
end
