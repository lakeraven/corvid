# frozen_string_literal: true

require "test_helper"

class Corvid::ChsReportingServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_rpt_test"

  # =============================================================================
  # FINANCIAL REPORT
  # =============================================================================

  test "financial_report returns hash with report_type" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert_equal :financial, report[:report_type]
    end
  end

  test "financial_report includes generated_at timestamp" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert_not_nil report[:generated_at]
    end
  end

  test "financial_report includes fiscal_year" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert_match(/\AFY\d{4}\z/, report[:fiscal_year])
    end
  end

  test "financial_report includes budget totals" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.key?(:total_budget)
      assert report.key?(:obligated)
      assert report.key?(:expended)
      assert report.key?(:remaining)
    end
  end

  test "financial_report calculates percent_used" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.key?(:percent_used)
      assert_kind_of Numeric, report[:percent_used]
    end
  end

  test "financial_report percent_used is a percentage" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report[:percent_used] >= 0.0
      assert report[:percent_used] <= 100.0
    end
  end

  test "financial_report includes obligation_summary" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.key?(:obligation_summary)
    end
  end

  test "financial_report includes outstanding_obligations" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report
      assert report.key?(:outstanding_obligations)
    end
  end

  test "financial_report accepts fiscal_year parameter" do
    with_tenant(TENANT) do
      report = Corvid::ChsReportingService.financial_report(fiscal_year: "FY2025")
      assert_equal "FY2025", report[:fiscal_year]
    end
  end

  # =============================================================================
  # FISCAL YEAR CALCULATION
  # =============================================================================

  test "fiscal year uses October as Q1 start" do
    with_tenant(TENANT) do
      # In Q2 (Jan-Mar), FY is current year
      # In Q1 (Oct-Dec), FY is next year
      report = Corvid::ChsReportingService.financial_report
      year = Date.current.year
      expected = Date.current.month >= 10 ? "FY#{year + 1}" : "FY#{year}"
      assert_equal expected, report[:fiscal_year]
    end
  end
end
