# frozen_string_literal: true

Given("the adapter has enrollment data for patient {string}:") do |patient_id, table|
  row = table.hashes.first
  Corvid.adapter.add_patient(patient_id,
    display_name: "TEST,PATIENT #{patient_id}",
    dob: row["dob"].present? ? Date.parse(row["dob"]) : nil,
    sex: "F",
    ssn_last4: row["ssn_last4"].presence
  )
  Corvid.adapter.add_enrollment(patient_id,
    enrolled: row["enrolled"] == "true",
    membership_number: row["membership_number"].presence,
    tribe_name: row["tribe_name"].presence,
    member_status: row["enrolled"] == "true" ? "enrolled" : "denied"
  )
  Corvid.adapter.add_residency(patient_id,
    on_reservation: row["on_reservation"] == "true",
    address: row["address"].presence,
    service_area: "test"
  )
end

Given("a second PRC referral {string} for patient {string}") do |referral_id, patient_id|
  @case2 = Corvid::Case.create!(
    patient_identifier: patient_id,
    facility_identifier: @facility
  )
  @referral2 = Corvid::PrcReferral.create!(
    case: @case2,
    referral_identifier: referral_id,
    facility_identifier: @facility
  )
end

When("I populate the eligibility checklist for the referral") do
  @checklist = Corvid::EligibilityChecklistService.populate!(@referral)
end

When("I populate the eligibility checklist for the second referral") do
  @checklist = Corvid::EligibilityChecklistService.populate!(@referral2)
end

Given("I have populated the eligibility checklist for the referral") do
  @checklist = Corvid::EligibilityChecklistService.populate!(@referral)
end

Given("all non-approval items are manually verified") do
  Corvid::EligibilityChecklistService.verify_item!(@referral, :application_complete, by: "pr_staff_001")
  Corvid::EligibilityChecklistService.verify_item!(@referral, :insurance_verified, source: "manual")
  Corvid::EligibilityChecklistService.verify_item!(@referral, :clinical_necessity_documented, source: "manual")
end

When("I manually verify {string} by {string}") do |item, by|
  Corvid::EligibilityChecklistService.verify_item!(@referral, item.to_sym, by: by)
end

When("I manually verify {string} with source {string}") do |item, source|
  Corvid::EligibilityChecklistService.verify_item!(@referral, item.to_sym, source: source)
end

When("manager {string} approves via the service") do |manager_id|
  Corvid::EligibilityChecklistService.approve!(@referral, by: manager_id)
end

When("the referral transitions through submit and begin_eligibility_review") do
  @referral.submit!
  @referral.begin_eligibility_review!
  @checklist = @referral.reload.eligibility_checklist
end

Then("the referral should have an eligibility checklist") do
  refute_nil @referral.reload.eligibility_checklist
end
