# frozen_string_literal: true

Given("a service request with urgency {string}") do |urgency|
  @urgency = urgency
  @sr = OpenStruct.new(
    urgency: urgency,
    reason_for_referral: @reason_for_referral || "Test referral",
    emergent?: urgency == "EMERGENT",
    urgent?: urgency == "URGENT",
    routine?: urgency == "ROUTINE",
    diagnosis_codes: nil,
    procedure_codes: nil,
    medical_priority_level: nil
  )
end

Given("the reason for referral is {string}") do |reason|
  @reason_for_referral = reason
  @sr = OpenStruct.new(
    urgency: @urgency || "ROUTINE",
    reason_for_referral: reason,
    emergent?: @urgency == "EMERGENT",
    urgent?: @urgency == "URGENT",
    routine?: (@urgency || "ROUTINE") == "ROUTINE",
    diagnosis_codes: nil,
    procedure_codes: nil,
    medical_priority_level: nil
  )
end

When("I assess medical priority using {string}") do |priority_system|
  @assessment = Corvid::MedicalPriorityService.assess(@sr, priority_system: priority_system)
end

Then("the priority level should be {int}") do |level|
  assert_equal level, @assessment.priority_level
end

Then("the priority name should include {string}") do |name|
  assert_includes @assessment.priority_name, name
end

Then("it should not require clinical review") do
  refute @assessment.requires_clinical_review?
end

Then("it should require clinical review") do
  assert @assessment.requires_clinical_review?
end

Then("the funding priority score should be {int}") do |score|
  assert_equal score, @assessment.funding_priority_score
end

Given("a PRC referral with an emergent service request") do
  @referral = create_referral_for_priority(emergent: true)
end

Given("a PRC referral with an urgent service request") do
  @referral = create_referral_for_priority(urgent: true)
end

Given("a PRC referral with a routine service request") do
  @referral = create_referral_for_priority
end

Given("a PRC referral with no service request") do
  kase = Corvid::Case.create!(
    patient_identifier: "pt_mp_bdd",
    lifecycle_status: "intake",
    facility_identifier: @facility || "fac_test"
  )
  @referral = Corvid::PrcReferral.create!(
    case: kase,
    referral_identifier: "ref_#{SecureRandom.hex(4)}"
  )
end

When("I assign medical priority") do
  @assign_result = Corvid::MedicalPriorityService.assign(@referral)
end

Then("the referral medical priority should be {int}") do |priority|
  assert_equal priority, @referral.reload.medical_priority
end

Then("the result should be {string}") do |value|
  assert_equal value, @assign_result.to_s
end

Then("the referral priority system should be {string}") do |system|
  assert_equal system, @referral.reload.priority_system
end

Then("the assessment hash should include priority_level {int}") do |level|
  assert_equal level, @assessment.to_h[:priority_level]
end

Then("the assessment hash should include priority_system {string}") do |system|
  assert_equal system, @assessment.to_h[:priority_system]
end

Then("the assessment hash should include funding_score {int}") do |score|
  assert_equal score, @assessment.to_h[:funding_score]
end

def create_referral_for_priority(emergent: false, urgent: false)
  kase = Corvid::Case.create!(
    patient_identifier: "pt_mp_bdd",
    lifecycle_status: "intake",
    facility_identifier: @facility || "fac_test"
  )
  referral = Corvid::PrcReferral.create!(
    case: kase,
    referral_identifier: "ref_#{SecureRandom.hex(4)}"
  )
  sr = OpenStruct.new(
    emergent?: emergent,
    urgent?: urgent,
    medical_priority_level: nil,
    reason_for_referral: "Test referral",
    urgency: emergent ? "EMERGENT" : (urgent ? "URGENT" : "ROUTINE")
  )
  referral.define_singleton_method(:service_request) { sr }
  referral
end
