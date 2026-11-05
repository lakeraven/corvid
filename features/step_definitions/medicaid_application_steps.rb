# frozen_string_literal: true

When("I record medicaid application filed on {string} from {string} in state {string}") do |date, source, state|
  check = @referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
  check.update!(
    application_date: Date.parse(date),
    application_date_source: source,
    medicaid_state_code: state
  )
  @check = check.reload
end

Then("the medicaid check should have application date {string}") do |date|
  check = @check || @referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
  assert_equal Date.parse(date), check.application_date
end

Then("the medicaid check medicaid state code should be {string}") do |state|
  check = @check || @referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
  assert_equal state, check.medicaid_state_code
end

When("the medicaid check is verified ineligible") do
  check = @check || @referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
  Corvid.adapter.define_singleton_method(:verify_eligibility) do |_patient_identifier, _resource_type|
    { eligible: false }
  end
  check.verify!
  @check = check.reload
end
