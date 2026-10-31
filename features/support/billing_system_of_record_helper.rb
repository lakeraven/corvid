# frozen_string_literal: true

# Seeds Corvid::BillingSystemSetting rows for billing system-of-record gates.
module BillingSystemOfRecordHelper
  def record_system_of_record(
    system_of_record: "corvid",
    facility_identifier:,
    tenant_identifier: Corvid::TenantContext.current_tenant_identifier,
    visit_type: nil,
    effective_on: Date.new(2000, 1, 1),
    expires_on: nil
  )
    Corvid::TenantContext.with_tenant(tenant_identifier) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: facility_identifier,
        visit_type: visit_type,
        system_of_record: system_of_record,
        effective_on: effective_on,
        expires_on: expires_on
      )
    end
  end
end
