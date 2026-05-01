# frozen_string_literal: true

# Medical priority step definitions

Given("the service request urgency is {string}") do |urgency|
  @service_request = OpenStruct.new(
    emergent?: urgency == "EMERGENT",
    urgent?: urgency == "URGENT",
    medical_priority_level: nil,
    reason_for_referral: "Test referral",
    diagnosis_codes: nil,
    procedure_codes: nil,
    urgency: urgency
  )
  @referral.define_singleton_method(:service_request) { @service_request }
end

Given("the service request urgency is nil") do
  @service_request = OpenStruct.new(
    emergent?: false,
    urgent?: false,
    medical_priority_level: nil,
    reason_for_referral: nil,
    diagnosis_codes: nil,
    procedure_codes: nil,
    urgency: nil
  )
end

When("medical priority is assigned") do
  # Stub service_request on the referral so MedicalPriorityService.assign can read it
  sr = @service_request
  @referral.define_singleton_method(:service_request) { sr }
  @priority_result_value = Corvid::MedicalPriorityService.assign(@referral)
  # Don't reload — that would lose the singleton method and the just-saved values
end

When("medical priority is assigned without a service request") do
  @priority_result_value = Corvid::MedicalPriorityService.assign(@referral)
end

When("medical priority is assessed") do
  @priority_result = Corvid::MedicalPriorityService.assess(@service_request)
end

Then("the priority level should be {int}") do |level|
  if @priority_result
    assert_equal level, @priority_result.priority_level
  else
    actual = Corvid::PrcReferral.find(@referral.id).medical_priority
    assert_equal level, actual
  end
end

Then("the priority system should be {string}") do |system|
  if @priority_result
    assert_equal system, @priority_result.priority_system
  else
    actual = Corvid::PrcReferral.find(@referral.id).priority_system
    assert_equal system, actual
  end
end

Then("the priority name should include {string}") do |name|
  result = @priority_result || Corvid::MedicalPriorityService.assess(@service_request)
  assert_includes result.priority_name, name,
    "Expected priority name to include '#{name}' but got '#{result.priority_name}'"
end

Then("the funding score should be {int}") do |score|
  assert_equal score, @priority_result.funding_priority_score
end

Then("the result should be essential") do
  assert @priority_result.essential?, "Expected result to be essential"
end

Then("the result should not be essential") do
  refute @priority_result.essential?, "Expected result to not be essential"
end

Then("the result should be necessary") do
  assert @priority_result.necessary?, "Expected result to be necessary"
end

Then("the result should not be necessary") do
  refute @priority_result.necessary?, "Expected result to not be necessary"
end

Then("the referral should have medical priority set") do
  fresh = Corvid::PrcReferral.find(@referral.id)
  refute_nil fresh.medical_priority, "Expected referral to have medical priority"
end

Then("the referral priority system should be {string}") do |system|
  fresh = Corvid::PrcReferral.find(@referral.id)
  assert_equal system, fresh.priority_system
end

Then("the priority should be unknown") do
  assert_equal :unknown, @priority_result_value
end
