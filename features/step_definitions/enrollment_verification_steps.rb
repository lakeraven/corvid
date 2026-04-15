# frozen_string_literal: true

Given("a patient {string} registered in the adapter as enrolled") do |patient_id|
  Corvid.adapter.add_patient(patient_id,
    display_name: "TEST,ENROLLED MEMBER",
    dob: Date.new(1985, 6, 15),
    sex: "F",
    ssn_last4: "1234"
  )
  Corvid.adapter.add_enrollment(patient_id,
    enrolled: true,
    membership_number: "YN-12345",
    tribe_name: "Test Tribe",
    blood_quantum: "1/4",
    member_status: "enrolled"
  )
  Corvid.adapter.add_residency(patient_id,
    on_reservation: true,
    address: "123 Main St, Toppenish, WA 98948",
    service_area: "yakama"
  )
end

Given("a patient {string} registered in the adapter as not enrolled") do |patient_id|
  Corvid.adapter.add_patient(patient_id,
    display_name: "TEST,NON ENROLLED",
    dob: Date.new(1990, 3, 1),
    sex: "M",
    ssn_last4: nil
  )
  Corvid.adapter.add_enrollment(patient_id,
    enrolled: false,
    membership_number: nil,
    tribe_name: nil,
    member_status: "denied"
  )
end

Given("a patient {string} registered in the adapter with an on-reservation address") do |patient_id|
  # Patient data may already exist from a previous step; just ensure residency is set
  Corvid.adapter.add_residency(patient_id,
    on_reservation: true,
    address: "456 Elm St, Toppenish, WA 98948",
    service_area: "yakama"
  )
end

Given("a patient {string} registered in the adapter with an off-reservation address") do |patient_id|
  Corvid.adapter.add_patient(patient_id,
    display_name: "TEST,OFF RESERVATION",
    dob: Date.new(1988, 11, 20),
    sex: "F",
    ssn_last4: "5678"
  )
  Corvid.adapter.add_residency(patient_id,
    on_reservation: false,
    address: "789 Oak Ave, Seattle, WA 98101",
    service_area: "seattle"
  )
end

When("I verify tribal enrollment for {string}") do |patient_id|
  @enrollment_result = Corvid.adapter.verify_tribal_enrollment(patient_id)
end

When("I verify identity documents for {string}") do |patient_id|
  @identity_result = Corvid.adapter.verify_identity_documents(patient_id)
end

When("I verify residency for {string}") do |patient_id|
  @residency_result = Corvid.adapter.verify_residency(patient_id)
end

Then("the enrollment result should show enrolled as true") do
  assert @enrollment_result[:enrolled], "Expected enrolled to be true"
end

Then("the enrollment result should show enrolled as false") do
  refute @enrollment_result[:enrolled], "Expected enrolled to be false"
end

Then("the enrollment result should include a membership number") do
  refute_nil @enrollment_result[:membership_number]
end

Then("the enrollment result should include a tribe name") do
  refute_nil @enrollment_result[:tribe_name]
end

Then("the identity result should show ssn_present as true") do
  assert @identity_result[:ssn_present], "Expected ssn_present to be true"
end

Then("the identity result should show dob_present as true") do
  assert @identity_result[:dob_present], "Expected dob_present to be true"
end

Then("the residency result should show on_reservation as true") do
  assert @residency_result[:on_reservation], "Expected on_reservation to be true"
end

Then("the residency result should show on_reservation as false") do
  refute @residency_result[:on_reservation], "Expected on_reservation to be false"
end

Then("the residency result should include an address") do
  refute_nil @residency_result[:address]
end
