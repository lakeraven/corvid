# frozen_string_literal: true

# Prior authorization step definitions

Given("a service request with urgency {string}") do |urgency|
  @pa_service_request = OpenStruct.new(
    urgency: urgency,
    emergent?: urgency == "EMERGENT",
    urgent?: urgency == "URGENT",
    routine?: urgency == "ROUTINE",
    estimated_cost: 0,
    authorization_required: false,
    authorization_reason: nil,
    requires_committee_review: false,
    case_manager_ien: nil,
    requested_on: Date.current
  )
end

Given("a service request with estimated cost {string}") do |cost|
  amount = cost.gsub(/[$,]/, "").to_f
  @pa_service_request = OpenStruct.new(
    urgency: "ROUTINE",
    emergent?: false,
    urgent?: false,
    routine?: true,
    estimated_cost: amount,
    authorization_required: false,
    authorization_reason: nil,
    requires_committee_review: false,
    case_manager_ien: nil,
    requested_on: Date.current
  )
end

Given("the service was requested today") do
  @pa_service_request.requested_on = Date.current
end

Given("the service was requested {int} days ago") do |days|
  @pa_service_request.requested_on = Date.current - days.days
end

Given("the service requires authorization") do
  @pa_service_request.authorization_required = true
end

Given("the service does not require authorization") do
  @pa_service_request.authorization_required = false
end

Given("no authorization reason is documented") do
  @pa_service_request.authorization_required = true
  @pa_service_request.authorization_reason = nil
end

Given("the service request requires committee review") do
  @pa_service_request.requires_committee_review = true
end

Given("no case manager is assigned") do
  @pa_service_request.case_manager_ien = nil
end

Given("a case manager is assigned") do
  @pa_service_request.case_manager_ien = "pr_cm_001"
  @pa_service_request.authorization_required = true unless @pa_service_request.authorization_required
  @pa_service_request.authorization_reason = "High-cost referral" unless @pa_service_request.authorization_reason
end

When("I check prior authorization requirements") do
  @pa_result = Corvid::PriorAuthorizationService.check(@pa_service_request)
end

Then("the authorization type should be {string}") do |type|
  assert_equal type.to_sym, @pa_result.authorization_type,
    "Expected authorization type '#{type}' but got '#{@pa_result.authorization_type}'"
end

Then("prior authorization should not be required") do
  refute @pa_result.requires_prior_authorization?, "Expected prior authorization to not be required"
end

Then("prior authorization should be required") do
  assert @pa_result.requires_prior_authorization?, "Expected prior authorization to be required"
end

Then("the referral should be within the notification window") do
  assert @pa_result.within_notification_window?, "Expected referral to be within notification window"
end

Then("the referral should not be within the notification window") do
  refute @pa_result.within_notification_window?, "Expected referral to not be within notification window"
end

Then("retroactive authorization should not be required") do
  refute @pa_result.requires_retroactive_authorization?, "Expected retroactive auth to not be required"
end

Then("retroactive authorization should be required") do
  assert @pa_result.requires_retroactive_authorization?, "Expected retroactive auth to be required"
end

Then("the notification deadline should be {int} days from today") do |days|
  expected = Date.current + days.days
  assert_equal expected, @pa_result.notification_deadline,
    "Expected deadline #{expected} but got #{@pa_result.notification_deadline}"
end

Then("the referral should be compliant") do
  assert @pa_result.compliant?, "Expected referral to be compliant but got: #{@pa_result.message}"
end

Then("the referral should not be compliant") do
  refute @pa_result.compliant?, "Expected referral to not be compliant"
end

Then("committee review should be required") do
  assert @pa_result.requires_committee_review?, "Expected committee review to be required"
end

Then("committee review should not be required") do
  refute @pa_result.requires_committee_review?, "Expected committee review to not be required"
end

Then("the authorization reason should mention {string}") do |text|
  assert_includes @pa_result.authorization_reason.to_s.downcase, text.downcase,
    "Expected authorization reason to mention '#{text}' but got '#{@pa_result.authorization_reason}'"
end

Then("a case manager should be required") do
  assert @pa_result.requires_case_manager?, "Expected case manager to be required"
end
