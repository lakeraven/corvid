# frozen_string_literal: true

require "test_helper"

class Corvid::ApiMetricsServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_metrics_unit"

  test "record! creates an ApiCallLog scoped to the current tenant" do
    with_tenant(TENANT) do
      Corvid::ApiMetricsService.record!(
        api: :pas, endpoint: "submit",
        patient_identifier: "pt_u_001", app_identifier: "app_a"
      )
      log = Corvid::ApiCallLog.last
      assert_equal TENANT, log.tenant_identifier
      assert_equal "pas", log.api_name
      assert_equal "submit", log.endpoint
      assert_equal "pt_u_001", log.patient_identifier
      assert_equal "app_a", log.app_identifier
      refute_nil log.called_at
    end
  end

  test "record! silently no-ops when tenant context is not set" do
    Corvid::TenantContext.reset!
    result = Corvid::ApiMetricsService.record!(api: :pas, endpoint: "submit")
    assert_nil result
  end

  test "annual_report aggregates unique patients, apps, and total calls" do
    with_tenant(TENANT) do
      Corvid::ApiMetricsService.record!(api: :pas, endpoint: "submit",
        patient_identifier: "pt_u_100", app_identifier: "app_x")
      Corvid::ApiMetricsService.record!(api: :pas, endpoint: "read",
        patient_identifier: "pt_u_100", app_identifier: "app_x")
      Corvid::ApiMetricsService.record!(api: :pas, endpoint: "read",
        patient_identifier: "pt_u_101", app_identifier: "app_y")
    end

    report = Corvid::ApiMetricsService.annual_report(tenant: TENANT, year: Date.current.year)
    assert_equal 3, report[:total_calls]
    assert_equal 2, report[:unique_patients]
    assert_equal 2, report[:unique_apps]
    assert_equal({ "submit" => 1, "read" => 2 }, report[:calls_by_endpoint])
  end

  test "annual_report can filter by api" do
    with_tenant(TENANT) do
      Corvid::ApiMetricsService.record!(api: :pas, endpoint: "submit",
        patient_identifier: "pt_u_200", app_identifier: "app_a")
      Corvid::ApiMetricsService.record!(api: :patient_access, endpoint: "read",
        patient_identifier: "pt_u_200", app_identifier: "app_a")
    end

    pas = Corvid::ApiMetricsService.annual_report(tenant: TENANT, year: Date.current.year, api: "pas")
    assert_equal 1, pas[:total_calls]
    pa = Corvid::ApiMetricsService.annual_report(tenant: TENANT, year: Date.current.year, api: "patient_access")
    assert_equal 1, pa[:total_calls]
  end

  test "annual_report scopes to the requested year" do
    with_tenant(TENANT) do
      Corvid::ApiMetricsService.record!(api: :pas, endpoint: "submit",
        patient_identifier: "pt_u_300", app_identifier: "app_a",
        called_at: Time.zone.local(2025, 6, 15))
      Corvid::ApiMetricsService.record!(api: :pas, endpoint: "submit",
        patient_identifier: "pt_u_301", app_identifier: "app_b",
        called_at: Time.zone.local(2026, 6, 15))
    end

    r2025 = Corvid::ApiMetricsService.annual_report(tenant: TENANT, year: 2025)
    r2026 = Corvid::ApiMetricsService.annual_report(tenant: TENANT, year: 2026)
    assert_equal 1, r2025[:total_calls]
    assert_equal 1, r2026[:total_calls]
  end

  test "annual_report does not count cross-tenant calls" do
    with_tenant(TENANT) do
      Corvid::ApiMetricsService.record!(api: :pas, endpoint: "submit",
        patient_identifier: "pt_u_400", app_identifier: "app_a")
    end
    Corvid::TenantContext.with_tenant("tnt_other_unit") do
      Corvid::ApiMetricsService.record!(api: :pas, endpoint: "submit",
        patient_identifier: "pt_u_401", app_identifier: "app_a")
    end

    report = Corvid::ApiMetricsService.annual_report(tenant: TENANT, year: Date.current.year)
    assert_equal 1, report[:total_calls]
  end
end
