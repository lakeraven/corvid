# frozen_string_literal: true

require "minitest/autorun"
require "corvid/tenant_context"

class Corvid::TenantContextTest < Minitest::Test
  def teardown
    Corvid::TenantContext.reset!
  end

  def test_current_tenant_identifier_starts_nil
    assert_nil Corvid::TenantContext.current_tenant_identifier
  end

  def test_current_facility_identifier_starts_nil
    assert_nil Corvid::TenantContext.current_facility_identifier
  end

  def test_current_tenant_identifier_can_be_set
    Corvid::TenantContext.current_tenant_identifier = "tnt_brokenrock"
    assert_equal "tnt_brokenrock", Corvid::TenantContext.current_tenant_identifier
  end

  def test_current_facility_identifier_can_be_set
    Corvid::TenantContext.current_facility_identifier = "fac_main_clinic"
    assert_equal "fac_main_clinic", Corvid::TenantContext.current_facility_identifier
  end

  def test_reset_clears_both_identifiers
    Corvid::TenantContext.current_tenant_identifier = "tnt_brokenrock"
    Corvid::TenantContext.current_facility_identifier = "fac_main_clinic"
    Corvid::TenantContext.reset!
    assert_nil Corvid::TenantContext.current_tenant_identifier
    assert_nil Corvid::TenantContext.current_facility_identifier
  end

  def test_with_tenant_yields_with_context_set
    Corvid::TenantContext.with_tenant("tnt_brokenrock") do
      assert_equal "tnt_brokenrock", Corvid::TenantContext.current_tenant_identifier
    end
  end

  def test_with_tenant_restores_previous_context
    Corvid::TenantContext.current_tenant_identifier = "tnt_outer"
    Corvid::TenantContext.with_tenant("tnt_inner") do
      assert_equal "tnt_inner", Corvid::TenantContext.current_tenant_identifier
    end
    assert_equal "tnt_outer", Corvid::TenantContext.current_tenant_identifier
  end

  def test_with_tenant_restores_even_on_exception
    Corvid::TenantContext.current_tenant_identifier = "tnt_outer"
    assert_raises(RuntimeError) do
      Corvid::TenantContext.with_tenant("tnt_inner") { raise "boom" }
    end
    assert_equal "tnt_outer", Corvid::TenantContext.current_tenant_identifier
  end

  def test_require_tenant_returns_current_when_set
    Corvid::TenantContext.current_tenant_identifier = "tnt_brokenrock"
    assert_equal "tnt_brokenrock", Corvid::TenantContext.require_tenant!
  end

  def test_require_tenant_raises_when_unset
    assert_raises(Corvid::MissingTenantContextError) do
      Corvid::TenantContext.require_tenant!
    end
  end

  def test_missing_tenant_context_error_inherits_from_standard_error
    assert Corvid::MissingTenantContextError < StandardError
  end
end
