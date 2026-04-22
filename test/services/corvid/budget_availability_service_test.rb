# frozen_string_literal: true

require "test_helper"

class Corvid::BudgetAvailabilityServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_budget_test"

  test "fiscal_year_budget returns budget from adapter" do
    with_tenant(TENANT) do
      result = Corvid::BudgetAvailabilityService.fiscal_year_budget
      assert result.is_a?(Hash) || result.is_a?(Numeric) || result.nil?
    end
  end

  test "remaining_budget returns a value" do
    with_tenant(TENANT) do
      result = Corvid::BudgetAvailabilityService.remaining_budget
      assert result.is_a?(Hash) || result.is_a?(Numeric) || result.nil?
    end
  end
end
