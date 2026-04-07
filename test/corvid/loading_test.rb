# frozen_string_literal: true

require "minitest/autorun"
require "corvid"

class Corvid::LoadingTest < Minitest::Test
  def test_corvid_module_is_defined
    assert defined?(Corvid)
  end

  def test_version_loaded
    refute_nil Corvid::VERSION
  end

  def test_value_objects_loaded
    assert defined?(Corvid::PatientReference)
    assert defined?(Corvid::PractitionerReference)
    assert defined?(Corvid::ReferralReference)
    assert defined?(Corvid::CareTeamMemberReference)
  end

  def test_tenant_context_loaded
    assert defined?(Corvid::TenantContext)
    assert defined?(Corvid::MissingTenantContextError)
  end

  def test_configuration_loaded
    assert defined?(Corvid::Configuration)
  end

  def test_adapters_loaded
    assert defined?(Corvid::Adapters::Base)
    assert defined?(Corvid::Adapters::MockAdapter)
    assert defined?(Corvid::Adapters::FhirAdapter)
  end

  def test_convenience_accessors_delegate_to_tenant_context
    Corvid.current_tenant_identifier = "tnt_test"
    assert_equal "tnt_test", Corvid::TenantContext.current_tenant_identifier
  ensure
    Corvid::TenantContext.reset!
  end

  def test_with_tenant_block_helper
    result = Corvid.with_tenant("tnt_test") { Corvid.current_tenant_identifier }
    assert_equal "tnt_test", result
    assert_nil Corvid.current_tenant_identifier
  end
end
