# frozen_string_literal: true

module Corvid
  # Per-tenant (optionally per-facility) adapter routing config. Resolved by
  # Corvid::AdapterRouter, per ADR 0006 Decision 4 / issue #390.
  #
  # Deliberately NOT `include TenantScoped`: this table is *how* a tenant's
  # adapter gets resolved in the first place, so it can't default_scope on
  # Corvid::TenantContext the way domain models do (the router is often
  # called before/without any ambient tenant context, e.g. resolving the
  # adapter for a background job that is itself setting that context).
  # Every query against this table filters by tenant_identifier explicitly.
  class TenantConnectionConfig < ::ActiveRecord::Base
    self.table_name = "corvid_tenant_connection_configs"

    # Stable adapter_type enum values per ADR 0006 Decision 4. "rpms_direct"
    # and "rpms_connector" have no built-in AdapterFactory builder in public
    # corvid — hosts register those via Corvid::AdapterFactory.register.
    ADAPTER_TYPES = %w[rpms_direct rpms_connector fhir mock].freeze

    validates :tenant_identifier, presence: true
    validates :adapter_type, presence: true, inclusion: { in: ADAPTER_TYPES }

    scope :active, -> { where(active: true) }
    scope :tenant_default, -> { where(facility_identifier: nil) }

    # Resolves the config row for (tenant_identifier, facility_identifier):
    # an exact facility match wins; otherwise falls back to the tenant-wide
    # default row (facility_identifier: nil). Returns nil if neither exists
    # (the caller — AdapterRouter — falls back to the Corvid.adapter global
    # in that case).
    def self.for(tenant_identifier, facility_identifier: nil)
      return nil if tenant_identifier.nil?

      scoped = active.where(tenant_identifier: tenant_identifier)
      scoped.find_by(facility_identifier: facility_identifier) ||
        (facility_identifier.present? && scoped.tenant_default.first) ||
        nil
    end
  end
end
