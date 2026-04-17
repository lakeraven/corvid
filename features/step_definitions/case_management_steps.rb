# frozen_string_literal: true

# Case management step definitions (ported from rpms_redux)

Given("a patient exists with DFN {string}") do |dfn|
  @patient_dfn = dfn
  Corvid.adapter.add_patient(dfn, display_name: "Test Patient", dob: Date.new(1980, 1, 1), sex: "M")
end

Given("a patient exists with DFN {string} and name {string}") do |dfn, name|
  @patient_dfn = dfn
  Corvid.adapter.add_patient(dfn, display_name: name, dob: Date.new(1980, 1, 1), sex: "M")
end

Given("a case exists for patient DFN {string}") do |dfn|
  @case = Corvid::Case.create!(
    patient_identifier: dfn,
    facility_identifier: @facility
  )
end

Given("a closed case exists for the patient") do
  @case = Corvid::Case.create!(
    patient_identifier: @patient_dfn,
    facility_identifier: @facility,
    status: :closed,
    closed_at: Time.current
  )
end

Given("the case has {int} referrals") do |count|
  count.times do |i|
    Corvid::PrcReferral.create!(
      case: @case,
      referral_identifier: "rf_#{@case.id}_#{i}",
      facility_identifier: @facility
    )
  end
end

Given("a case exists without cached patient data") do
  @case = Corvid::Case.create!(
    patient_identifier: "pt_uncached",
    facility_identifier: @facility
  )
end

When("I create a case for the patient") do
  @case = Corvid::Case.create!(
    patient_identifier: @patient_dfn,
    facility_identifier: @facility
  )
end

When("I switch to facility {string} with code {string}") do |_name, code|
  # Use the facility code (the identifier) as the active facility so
  # subsequent queries actually see the switch. Previously this step
  # set @other_facility to a hard-coded value and never updated @facility,
  # which made the "Case is scoped to facility" scenario tautological.
  @other_facility = code
  @facility = code
  Corvid::TenantContext.current_facility_identifier = code
end

When("I close the case") do
  @case.update!(status: :closed, closed_at: Time.current)
end

When("I reactivate the case") do
  @case.update!(status: :active, closed_at: nil)
end

When("I create a PRC referral for the case") do
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: "rf_#{@case.id}_main",
    facility_identifier: @facility
  )
end

When("I cache the patient data") do
  @case.cache_patient_data!
end

Then("a case should exist for patient {string}") do |dfn|
  assert Corvid::Case.exists?(patient_identifier: dfn)
end

Then("the case status should be {string}") do |status|
  @case.reload
  assert_equal status, @case.status
end

Then("I should not see the case") do
  scope = Corvid::Case.where(facility_identifier: @other_facility)
  refute_includes scope.pluck(:id), @case.id
end

Then("the case should have {int} referral") do |count|
  @case.reload
  assert_equal count, @case.prc_referrals.count
end

Then("the case should have {int} referrals") do |count|
  @case.reload
  assert_equal count, @case.prc_referrals.count
end

Then("the case display name should be {string}") do |name|
  @case.reload
  assert_equal name, @case.display_name
end
