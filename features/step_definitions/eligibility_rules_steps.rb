# frozen_string_literal: true

require "corvid/rules_engine"

Given("a patient with valid enrollment {string} in service area {string}") do |enrollment, area|
  @enrollment_number = enrollment
  @service_area = area
end

Given("a referral for {string} with urgency {string} and coverage {string}") do |reason, urgency, coverage|
  @reason_for_referral = reason
  @urgency = urgency.to_sym
  @coverage_type = coverage
end

When("I evaluate eligibility") do
  ruleset = Corvid::PrcEligibilityRuleset.new
  @engine = Corvid::RulesEngine.new(ruleset)
  @engine.set_facts(
    enrollment_number: @enrollment_number,
    service_area: @service_area,
    reason_for_referral: @reason_for_referral,
    urgency: @urgency,
    coverage_type: @coverage_type,
    service_requested: @reason_for_referral
  )
  @result = @engine.evaluate(:is_eligible)
end

Then("the patient should be eligible") do
  assert @result.value, "Expected patient to be eligible but was not. Failed: #{@result.failed_facts.map(&:name).join(', ')}"
end

Then("the patient should not be eligible") do
  refute @result.value, "Expected patient to not be eligible"
end

Then("the message should include {string}") do |text|
  facts = @engine.all_evaluated_facts
  context = {
    enrollment_number: @enrollment_number,
    service_area: @service_area,
    reason_for_referral: @reason_for_referral,
    urgency: @urgency,
    coverage_type: @coverage_type,
    service_requested: @reason_for_referral,
    has_clinical_justification: facts[:has_clinical_justification]&.value
  }
  messages = facts.map { |name, fact| Corvid::PrcEligibilityRuleset.message_for(name, fact.value, context) }
  assert messages.any? { |m| m.include?(text) }, "Expected a message containing '#{text}' but got:\n#{messages.join("\n")}"
end
