# frozen_string_literal: true

require "test_helper"

class Corvid::BudgetAvailabilityServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_budget_test"

  # =============================================================================
  # FISCAL YEAR BUDGET
  # =============================================================================

  test "fiscal_year_budget returns numeric value" do
    with_tenant(TENANT) do
      result = Corvid::BudgetAvailabilityService.fiscal_year_budget
      assert_kind_of Numeric, result
    end
  end

  test "fiscal_year_budget returns default when adapter returns nil" do
    with_tenant(TENANT) do
      result = Corvid::BudgetAvailabilityService.fiscal_year_budget
      assert_equal 1_000_000.0, result
    end
  end

  # =============================================================================
  # REMAINING BUDGET
  # =============================================================================

  test "remaining_budget returns numeric value" do
    with_tenant(TENANT) do
      result = Corvid::BudgetAvailabilityService.remaining_budget
      assert_kind_of Numeric, result
    end
  end

  # =============================================================================
  # RESERVED FUNDS
  # =============================================================================

  test "reserved_funds returns numeric value" do
    with_tenant(TENANT) do
      result = Corvid::BudgetAvailabilityService.reserved_funds
      assert_kind_of Numeric, result
    end
  end

  # =============================================================================
  # CURRENT QUARTER
  # =============================================================================

  test "current_quarter returns FY format" do
    result = Corvid::BudgetAvailabilityService.current_quarter
    assert_match(/\AFY\d{4}-Q[1-4]\z/, result)
  end

  test "current_quarter maps October to Q1 of next FY" do
    travel_to Date.new(2025, 10, 15) do
      assert_equal "FY2026-Q1", Corvid::BudgetAvailabilityService.current_quarter
    end
  end

  test "current_quarter maps January to Q2 of current FY" do
    travel_to Date.new(2026, 1, 15) do
      assert_equal "FY2026-Q2", Corvid::BudgetAvailabilityService.current_quarter
    end
  end

  test "current_quarter maps April to Q3 of current FY" do
    travel_to Date.new(2026, 4, 15) do
      assert_equal "FY2026-Q3", Corvid::BudgetAvailabilityService.current_quarter
    end
  end

  test "current_quarter maps July to Q4 of current FY" do
    travel_to Date.new(2026, 7, 15) do
      assert_equal "FY2026-Q4", Corvid::BudgetAvailabilityService.current_quarter
    end
  end

  # =============================================================================
  # COMMITTEE THRESHOLD
  # =============================================================================

  test "COMMITTEE_REVIEW_THRESHOLD is 50_000" do
    assert_equal 50_000.0, Corvid::BudgetAvailabilityService::COMMITTEE_REVIEW_THRESHOLD
  end
end
