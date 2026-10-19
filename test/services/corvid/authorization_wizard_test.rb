# frozen_string_literal: true

require "test_helper"

class Corvid::AuthorizationWizardTest < ActiveSupport::TestCase
  TENANT = "tnt_wizard_blank"

  test "initialize treats blank tenant_identifier as absent and uses TenantContext" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(tenant_identifier: "")
      assert_equal TENANT, wizard.tenant_identifier
    end
  end

  test "initialize treats whitespace tenant_identifier as absent and uses TenantContext" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(tenant_identifier: "   ")
      assert_equal TENANT, wizard.tenant_identifier
    end
  end

  test "initialize raises when tenant_identifier is blank and TenantContext has no tenant" do
    assert_raises(ArgumentError, /tenant_identifier required/) do
      Corvid::AuthorizationWizard.new(tenant_identifier: "")
    end
  end

  test "initialize treats blank facility_identifier as absent and uses TenantContext facility" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = "fac_ambient"
      wizard = Corvid::AuthorizationWizard.new(facility_identifier: "")
      assert_equal "fac_ambient", wizard.facility_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "initialize treats whitespace facility_identifier as absent and uses TenantContext facility" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = "fac_ambient"
      wizard = Corvid::AuthorizationWizard.new(facility_identifier: "  ")
      assert_equal "fac_ambient", wizard.facility_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end
end
