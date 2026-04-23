# frozen_string_literal: true

Given("a PRC referral with estimated cost {string}") do |cost|
  amount = cost.delete("$,").to_f
  kase = Corvid::Case.create!(
    patient_identifier: "pt_budget_test",
    lifecycle_status: "intake",
    facility_identifier: @facility || "fac_test"
  )
  @referral = Corvid::PrcReferral.create!(
    case: kase,
    referral_identifier: "ref_#{SecureRandom.hex(4)}",
    estimated_cost: amount
  )
end

When("I check budget availability") do
  budget = Corvid::BudgetAvailabilityService.fiscal_year_budget
  cost = @referral.estimated_cost.to_f
  @funds_available = cost <= budget
end

Then("funds should be available") do
  assert @funds_available, "Expected funds to be available"
end

Then("funds should not be available") do
  refute @funds_available, "Expected funds to NOT be available"
end

When("I check if committee review is required") do
  @requires_committee = @referral.requires_committee?
end

Then("committee review should be required") do
  assert @requires_committee, "Expected committee review to be required"
end

Then("committee review should not be required") do
  refute @requires_committee, "Expected committee review NOT to be required"
end

When("I check the current quarter") do
  @quarter = Corvid::BudgetAvailabilityService.current_quarter
end

Then("the quarter should match a fiscal year format") do
  assert_match(/\AFY\d{4}-Q[1-4]\z/, @quarter)
end

Then("the quarter should include {string}") do |text|
  assert_includes @quarter, text
end

Given("the date is October 15") do
  # Stub Date.current for this scenario
  @original_date_current = Date.current
  allow_date = Date.new(Date.current.year, 10, 15)
  Date.singleton_class.alias_method(:__original_current, :current)
  Date.define_singleton_method(:current) { allow_date }
end

After do
  if Date.respond_to?(:__original_current)
    Date.singleton_class.alias_method(:current, :__original_current)
    Date.singleton_class.remove_method(:__original_current) rescue nil
  end
end

Given("no budget data is configured") do
  # Mock adapter returns nil by default
end

When("I check the fiscal year budget") do
  @budget = Corvid::BudgetAvailabilityService.fiscal_year_budget
end

Then("the budget should default to {string}") do |amount|
  assert_equal amount.delete("$,").to_f, @budget
end

When("I check the committee review threshold") do
  @threshold = Corvid::BudgetAvailabilityService::COMMITTEE_REVIEW_THRESHOLD
end

Then("the threshold should be {string}") do |amount|
  assert_equal amount.delete("$,").to_f, @threshold
end
