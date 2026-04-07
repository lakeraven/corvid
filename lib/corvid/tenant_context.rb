# frozen_string_literal: true

module Corvid
  # Raised when a query or operation that requires tenant context runs
  # without a current_tenant_identifier set. Per ADR 0002, this is the
  # fail-loud enforcement that prevents accidental cross-tenant access.
  class MissingTenantContextError < StandardError; end

  # Thread-local tenant and facility context.
  #
  # In Rails apps, prefer ActiveSupport::CurrentAttributes (the engine's
  # Current class wraps this for Rails integration). This module provides
  # the underlying storage that works in any Ruby context (background jobs,
  # console, plain Ruby scripts).
  #
  # Per ADR 0002:
  # - tenant_identifier is required (raises if missing when accessed via require_tenant!)
  # - facility_identifier is optional
  # - Background jobs MUST set tenant context explicitly
  module TenantContext
    THREAD_KEY_TENANT = :corvid_tenant_identifier
    THREAD_KEY_FACILITY = :corvid_facility_identifier

    module_function

    def current_tenant_identifier
      Thread.current[THREAD_KEY_TENANT]
    end

    def current_tenant_identifier=(identifier)
      Thread.current[THREAD_KEY_TENANT] = identifier
    end

    def current_facility_identifier
      Thread.current[THREAD_KEY_FACILITY]
    end

    def current_facility_identifier=(identifier)
      Thread.current[THREAD_KEY_FACILITY] = identifier
    end

    # Yields a block with the given tenant identifier set, restoring the
    # previous value (or nil) afterward — even on exception.
    def with_tenant(identifier)
      previous = current_tenant_identifier
      self.current_tenant_identifier = identifier
      yield
    ensure
      self.current_tenant_identifier = previous
    end

    # Returns the current tenant identifier or raises if unset.
    # Use this in default_scope and other places where tenant context
    # must be present (per ADR 0002).
    def require_tenant!
      identifier = current_tenant_identifier
      raise MissingTenantContextError, "Corvid.current_tenant_identifier not set" unless identifier
      identifier
    end

    def reset!
      Thread.current[THREAD_KEY_TENANT] = nil
      Thread.current[THREAD_KEY_FACILITY] = nil
    end
  end
end
