# frozen_string_literal: true

module Corvid
  # Per ADR 0002: every Case-domain model is tenant-scoped. The default_scope
  # raises if Corvid.current_tenant_identifier is unset, preventing accidental
  # cross-tenant queries from console, jobs, or middleware that forgot to set
  # context.
  module TenantScoped
    extend ActiveSupport::Concern

    included do
      validates :tenant_identifier, presence: true

      default_scope do
        tenant = Corvid::TenantContext.current_tenant_identifier
        raise Corvid::MissingTenantContextError, "current_tenant_identifier not set for #{name}" unless tenant
        where(tenant_identifier: tenant)
      end

      scope :for_facility, ->(identifier) { where(facility_identifier: identifier) }
      scope :all_facilities_in_tenant, -> { all }

      before_validation :default_tenant_identifier_from_context
    end

    private

    def default_tenant_identifier_from_context
      self.tenant_identifier ||= Corvid::TenantContext.current_tenant_identifier
    end
  end
end
