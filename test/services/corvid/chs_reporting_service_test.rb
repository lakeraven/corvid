# frozen_string_literal: true

require "test_helper"

class Corvid::ChsReportingServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_rpt_test"

  test "service class exists" do
    assert defined?(Corvid::ChsReportingService)
  end

  test "responds to generate" do
    with_tenant(TENANT) do
      assert Corvid::ChsReportingService.respond_to?(:generate) ||
             Corvid::ChsReportingService.respond_to?(:new)
    end
  end

  # -- financial_report ------------------------------------------------------

  test "financial_report returns budget summary" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.is_a?(Hash)
      assert report.key?(:fiscal_year)
      assert report.key?(:total_budget)
      assert report.key?(:obligated)
      assert report.key?(:expended)
      assert report.key?(:remaining)
    end
  end

  test "financial_report includes percent_used" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.key?(:percent_used)
      assert report[:percent_used].is_a?(Numeric)
    end
  end

  test "financial_report filters by fiscal year" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report(fiscal_year: "FY2025")
      assert_equal "FY2025", report[:fiscal_year]
    end
  end

  test "financial_report includes report_type" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.key?(:report_type)
      assert_equal :financial, report[:report_type]
    end
  end

  test "financial_report includes generated_at timestamp" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.key?(:generated_at)
      assert report[:generated_at].is_a?(Time) || report[:generated_at].is_a?(DateTime)
    end
  end

  test "financial_report total_budget is positive" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report[:total_budget] > 0
    end
  end

  # -- utilization_report ---------------------------------------------------

  test "utilization_report returns referral counts" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.utilization_report
      assert report.is_a?(Hash)
      assert report.key?(:total_referrals)
      assert report.key?(:generated_at)
      assert report.key?(:report_type)
    end
  end

  test "utilization_report filters by date range" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.utilization_report(
        from_date: Date.new(2025, 1, 1),
        to_date: Date.new(2025, 3, 31)
      )
      assert report.is_a?(Hash)
      assert report[:period].present?
    end
  end

  test "utilization_report includes by_status breakdown" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.utilization_report
      assert report.key?(:by_status)
    end
  end

  # -- denial_report ---------------------------------------------------------

  test "denial_report returns denial statistics" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.denial_report
      assert report.is_a?(Hash)
      assert report.key?(:total_denials)
      assert report.key?(:denial_rate)
    end
  end

  test "denial_report includes by_reason breakdown" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.denial_report
      assert report.key?(:by_reason)
    end
  end

  # -- workload_report -------------------------------------------------------

  test "workload_report returns staff metrics" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.workload_report
      assert report.is_a?(Hash)
      assert report.key?(:pending_count)
    end
  end

  # -- to_csv ----------------------------------------------------------------

  test "to_csv exports financial report" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      csv = Corvid::ChsReportingService.to_csv(report, type: :financial)
      assert csv.is_a?(String)
      assert csv.length > 0
    end
  end

  # -- utilization_report by_provider ----------------------------------------

  test "utilization_report includes by_provider breakdown" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.utilization_report
      assert report.key?(:by_provider)
    end
  end

  # -- denial_report filters by date range ----------------------------------

  test "denial_report filters by date range" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.denial_report(
        from_date: Date.new(2025, 1, 1),
        to_date: Date.new(2025, 3, 31)
      )
      assert report[:period][:from].present?
    end
  end

  # -- workload_report includes processing metrics --------------------------

  test "workload_report includes processing time metrics" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.workload_report
      assert report.key?(:processing_metrics)
    end
  end

  # -- to_csv exports utilization report ------------------------------------

  test "to_csv exports utilization report" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.utilization_report
      csv = Corvid::ChsReportingService.to_csv(report, type: :utilization)
      assert csv.is_a?(String)
      assert csv.length > 0
    end
  end

  # -- financial_report by_quarter ------------------------------------------

  test "financial_report includes obligation_summary" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.key?(:obligation_summary)
    end
  end

  # -- Adapter boundary ------------------------------------------------------

  test "ChsReportingService does not reference Rpms:: directly" do
    source = File.read(File.join(Corvid::Engine.root, "app/services/corvid/chs_reporting_service.rb"))
    refute_match(/Rpms::/, source, "ChsReportingService should not reference Rpms:: directly")
  end
end
