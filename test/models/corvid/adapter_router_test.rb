# frozen_string_literal: true

require "test_helper"

class Corvid::AdapterRouterTest < ActiveSupport::TestCase
  teardown do
    Corvid.configuration.adapter_router_cache_ttl = 60
    Corvid.configuration.secret_reader = Corvid::SecretReader::Env.new
  end

  # -- fallback to the static global ---------------------------------------

  test "resolve falls back to Corvid.adapter when no config exists for the tenant" do
    fallback = Corvid::Adapters::MockAdapter.new
    Corvid.configure { |c| c.adapter = fallback }

    assert_same fallback, Corvid::AdapterRouter.resolve("tnt_no_config")
  end

  test "resolve ignores an inactive config row and falls back to the global" do
    fallback = Corvid::Adapters::MockAdapter.new
    Corvid.configure { |c| c.adapter = fallback }
    Corvid::TenantConnectionConfig.create!(
      tenant_identifier: "tnt_inactive", adapter_type: "fhir",
      endpoint: "https://fhir.example.org", active: false
    )

    assert_same fallback, Corvid::AdapterRouter.resolve("tnt_inactive")
  end

  test "resolve raises ArgumentError without a tenant_identifier" do
    assert_raises(ArgumentError) { Corvid::AdapterRouter.resolve(nil) }
  end

  # -- factory resolution ----------------------------------------------------

  test "resolve builds via the factory for a tenant-level mock config" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_mock", adapter_type: "mock")

    adapter = Corvid::AdapterRouter.resolve("tnt_mock")
    assert_instance_of Corvid::Adapters::MockAdapter, adapter
  end

  test "resolve raises UnknownAdapterTypeError for an rpms_direct config with no vendor builder registered" do
    Corvid::TenantConnectionConfig.create!(
      tenant_identifier: "tnt_rpms", adapter_type: "rpms_direct", endpoint: "rpms://example"
    )

    assert_raises(Corvid::AdapterFactory::UnknownAdapterTypeError) do
      Corvid::AdapterRouter.resolve("tnt_rpms")
    end
  end

  test "resolve uses a vendor-registered builder for rpms_direct" do
    fake_rpms_adapter = Object.new
    Corvid::AdapterFactory.register("rpms_direct") { |_config, _secret| fake_rpms_adapter }
    Corvid::TenantConnectionConfig.create!(
      tenant_identifier: "tnt_rpms2", adapter_type: "rpms_direct", endpoint: "rpms://example"
    )

    assert_same fake_rpms_adapter, Corvid::AdapterRouter.resolve("tnt_rpms2")
  end

  # -- per-tenant / per-facility selection ------------------------------------

  test "resolve routes two tenants with different adapter types to distinct adapters" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_a", adapter_type: "mock")
    Corvid::TenantConnectionConfig.create!(
      tenant_identifier: "tnt_b", adapter_type: "fhir", endpoint: "https://fhir.tnt-b.example.org"
    )

    adapter_a = Corvid::AdapterRouter.resolve("tnt_a")
    adapter_b = Corvid::AdapterRouter.resolve("tnt_b")

    assert_instance_of Corvid::Adapters::MockAdapter, adapter_a
    assert_instance_of Corvid::Adapters::FhirAdapter, adapter_b
    assert_equal "https://fhir.tnt-b.example.org", adapter_b.base_url
  end

  test "resolve prefers a facility-specific config over the tenant-wide default" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_multi", adapter_type: "mock")
    Corvid::TenantConnectionConfig.create!(
      tenant_identifier: "tnt_multi", facility_identifier: "fac_1",
      adapter_type: "fhir", endpoint: "https://fhir.fac1.example.org"
    )

    facility_adapter = Corvid::AdapterRouter.resolve("tnt_multi", facility_identifier: "fac_1")
    other_facility_adapter = Corvid::AdapterRouter.resolve("tnt_multi", facility_identifier: "fac_2")

    assert_instance_of Corvid::Adapters::FhirAdapter, facility_adapter
    assert_instance_of Corvid::Adapters::MockAdapter, other_facility_adapter
  end

  # -- secret manager lookup ---------------------------------------------------

  test "resolve resolves secret_ref via Corvid.configuration.secret_reader" do
    stub_reader = Class.new do
      def fetch(secret_ref)
        raise KeyError, secret_ref.to_s unless secret_ref == "fhir/tnt_secret"

        "resolved-token"
      end
    end.new
    Corvid.configure { |c| c.secret_reader = stub_reader }
    Corvid::TenantConnectionConfig.create!(
      tenant_identifier: "tnt_secret", adapter_type: "fhir",
      endpoint: "https://fhir.example.org", secret_ref: "fhir/tnt_secret"
    )

    adapter = Corvid::AdapterRouter.resolve("tnt_secret")
    assert_equal "resolved-token", adapter.instance_variable_get(:@bearer_token)
  end

  test "resolve propagates a secret_reader failure instead of silently building an unauthenticated adapter" do
    stub_reader = Class.new do
      def fetch(secret_ref)
        raise KeyError, "not found: #{secret_ref}"
      end
    end.new
    Corvid.configure { |c| c.secret_reader = stub_reader }
    Corvid::TenantConnectionConfig.create!(
      tenant_identifier: "tnt_secret_missing", adapter_type: "fhir",
      endpoint: "https://fhir.example.org", secret_ref: "fhir/does-not-exist"
    )

    assert_raises(KeyError) { Corvid::AdapterRouter.resolve("tnt_secret_missing") }
  end

  # -- caching -----------------------------------------------------------------

  test "resolve caches the built adapter across calls" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_cache", adapter_type: "mock")

    first = Corvid::AdapterRouter.resolve("tnt_cache")
    second = Corvid::AdapterRouter.resolve("tnt_cache")

    assert_same first, second
  end

  test "resolve force: true bypasses the cache and rebuilds" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_force", adapter_type: "mock")

    first = Corvid::AdapterRouter.resolve("tnt_force")
    second = Corvid::AdapterRouter.resolve("tnt_force", force: true)

    refute_same first, second
  end

  test "invalidate busts the cache for one tenant/facility pair only" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_inv_a", adapter_type: "mock")
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_inv_b", adapter_type: "mock")
    a1 = Corvid::AdapterRouter.resolve("tnt_inv_a")
    b1 = Corvid::AdapterRouter.resolve("tnt_inv_b")

    Corvid::AdapterRouter.invalidate("tnt_inv_a")

    refute_same a1, Corvid::AdapterRouter.resolve("tnt_inv_a")
    assert_same b1, Corvid::AdapterRouter.resolve("tnt_inv_b")
  end

  test "invalidate_all clears every cached entry" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_all_a", adapter_type: "mock")
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_all_b", adapter_type: "mock")
    a1 = Corvid::AdapterRouter.resolve("tnt_all_a")
    b1 = Corvid::AdapterRouter.resolve("tnt_all_b")

    Corvid::AdapterRouter.invalidate_all!

    refute_same a1, Corvid::AdapterRouter.resolve("tnt_all_a")
    refute_same b1, Corvid::AdapterRouter.resolve("tnt_all_b")
  end

  test "cache entry expires after the configured ttl" do
    Corvid.configuration.adapter_router_cache_ttl = 0
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_ttl", adapter_type: "mock")

    first = Corvid::AdapterRouter.resolve("tnt_ttl")
    sleep 0.01
    second = Corvid::AdapterRouter.resolve("tnt_ttl")

    refute_same first, second
  end

  test "a fresh config change is not visible until the cache expires or is invalidated" do
    Corvid::TenantConnectionConfig.create!(tenant_identifier: "tnt_stale", adapter_type: "mock")
    first = Corvid::AdapterRouter.resolve("tnt_stale")
    assert_instance_of Corvid::Adapters::MockAdapter, first

    Corvid::TenantConnectionConfig.find_by(tenant_identifier: "tnt_stale")
      .update!(adapter_type: "fhir", endpoint: "https://fhir.example.org")

    # Still cached: same (mock) instance, not yet the new fhir config.
    assert_same first, Corvid::AdapterRouter.resolve("tnt_stale")

    Corvid::AdapterRouter.invalidate("tnt_stale")
    assert_instance_of Corvid::Adapters::FhirAdapter, Corvid::AdapterRouter.resolve("tnt_stale")
  end
end
