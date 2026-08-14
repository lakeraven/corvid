# frozen_string_literal: true

require "test_helper"

class Corvid::TenantConnectionConfigTest < ActiveSupport::TestCase
  test "requires tenant_identifier" do
    config = Corvid::TenantConnectionConfig.new(adapter_type: "mock")
    refute config.valid?
    assert_includes config.errors[:tenant_identifier], "can't be blank"
  end

  test "requires adapter_type to be one of the known enum values" do
    config = Corvid::TenantConnectionConfig.new(tenant_identifier: "tnt_x", adapter_type: "not_a_real_type")
    refute config.valid?
    assert_includes config.errors[:adapter_type], "is not included in the list"
  end

  test "accepts every ADR 0006 adapter_type" do
    Corvid::TenantConnectionConfig::ADAPTER_TYPES.each_with_index do |type, i|
      config = Corvid::TenantConnectionConfig.new(tenant_identifier: "tnt_types_#{i}", adapter_type: type)
      assert config.valid?, "#{type} should be valid: #{config.errors.full_messages}"
    end
  end

  test "a duplicate tenant-default row (facility nil) violates the unique index" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_dup", adapter_type: "mock")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_dup", adapter_type: "fhir", endpoint: "https://x")
    end
  end

  test "a duplicate tenant+facility row violates the unique index" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_dup2", facility_identifier: "fac_1", adapter_type: "mock")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_dup2", facility_identifier: "fac_1", adapter_type: "fhir", endpoint: "https://x")
    end
  end

  test "different facilities under the same tenant do not collide" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_multi_fac", facility_identifier: "fac_1", adapter_type: "mock")
    assert Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_multi_fac", facility_identifier: "fac_2", adapter_type: "mock").persisted?
  end

  # -- .for -------------------------------------------------------------------

  test ".for returns nil when the tenant has no config" do
    assert_nil Corvid::TenantConnectionConfig.for("tnt_missing")
  end

  test ".for returns nil for a nil tenant_identifier" do
    assert_nil Corvid::TenantConnectionConfig.for(nil)
  end

  test ".for returns the tenant-default row when no facility_identifier is given" do
    config = Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_for_a", adapter_type: "mock")
    assert_equal config, Corvid::TenantConnectionConfig.for("tnt_for_a")
  end

  test ".for falls back to the tenant-default row when the requested facility has no specific row" do
    default = Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_for_b", adapter_type: "mock")
    assert_equal default, Corvid::TenantConnectionConfig.for("tnt_for_b", facility_identifier: "fac_unknown")
  end

  test ".for prefers the facility-specific row when both exist" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_for_c", adapter_type: "mock")
    facility_config = Corvid::TenantConnectionConfig.create!(
      tenant_identifier: "tnt_for_c", facility_identifier: "fac_1", adapter_type: "fhir", endpoint: "https://x"
    )
    assert_equal facility_config, Corvid::TenantConnectionConfig.for("tnt_for_c", facility_identifier: "fac_1")
  end

  test ".for excludes inactive rows" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_for_inactive", adapter_type: "mock", active: false)
    assert_nil Corvid::TenantConnectionConfig.for("tnt_for_inactive")
  end
end
