# frozen_string_literal: true

# Budget availability step definitions

Given("the referral estimated cost is {string}") do |cost|
  amount = cost.gsub(/[$,]/, "").to_f
  @referral.update!(estimated_cost: amount)
end

Given("no cost estimate is provided") do
  @referral.update!(estimated_cost: nil)
end

When("I check budget availability") do
  @budget_result = Corvid::BudgetAvailabilityService.check(@referral)
end

When("I reserve funds for the referral") do
  @reservation_success = Corvid::BudgetAvailabilityService.reserve_funds_if_available(
    @referral.referral_identifier,
    @referral.estimated_cost
  )
end

Then("funds should be available") do
  assert @budget_result.funds_available?, "Expected funds to be available"
end

Then("funds should not be available") do
  refute @budget_result.funds_available?, "Expected funds to not be available"
end

Then("the referral should be budget compliant") do
  assert @budget_result.budget_sufficient?, "Expected referral to be budget compliant"
  assert @budget_result.funds_available?, "Expected funds to be available"
end

Then("the referral should not be budget compliant") do
  refute(@budget_result.budget_sufficient? && @budget_result.funds_available?,
    "Expected referral to not be budget compliant")
end

Then("a cost estimate should be required") do
  assert @budget_result.requires_cost_estimate?, "Expected cost estimate to be required"
end

Then("budget committee review should be required") do
  assert @budget_result.requires_committee_review?, "Expected committee review to be required"
end

Then("budget committee review should not be required") do
  refute @budget_result.requires_committee_review?, "Expected committee review to not be required"
end

Then("the fiscal year should use October start") do
  fiscal_year = @budget_result.fiscal_year
  assert_match(/\AFY\d{4}\z/, fiscal_year)

  current_month = Date.current.month
  expected_fy = current_month >= 10 ? "FY#{Date.current.year + 1}" : "FY#{Date.current.year}"
  assert_equal expected_fy, fiscal_year, "Expected fiscal year to be #{expected_fy}"
end

Then("the budget check result should have a positive total budget") do
  assert @budget_result.total_budget > 0, "Expected positive total budget"
end

Then("the funding source should be valid") do
  assert @budget_result.valid_funding_source?, "Expected valid funding source"
end

Then("the reservation should be successful") do
  assert @reservation_success, "Expected fund reservation to succeed"
end
