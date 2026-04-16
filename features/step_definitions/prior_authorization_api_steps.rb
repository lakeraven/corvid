# frozen_string_literal: true

# CMS-0057-F Prior Authorization API (Da Vinci PAS) step definitions

def build_fhir_claim(patient_id:, service: "Cardiology Consultation", cost: 5000, provider: nil)
  {
    resourceType: "Claim",
    status: "active",
    use: "preauthorization",
    patient: { reference: "Patient/#{patient_id}" },
    provider: provider ? { reference: "Practitioner/#{provider}" } : nil,
    total: { value: cost, currency: "USD" },
    item: [ { productOrService: service } ]
  }.compact
end

When("a provider submits a FHIR PA request for service {string} with estimated cost {int}") do |service, cost|
  @fhir_claim = build_fhir_claim(patient_id: @case.patient_identifier, service: service, cost: cost)
  @claim_response = Corvid::PriorAuthorizationApiService.submit_from_claim(@fhir_claim)
  @referral = Corvid::PrcReferral.find_by!(referral_identifier: @claim_response[:id])
end

When("a provider {string} submits a FHIR PA request for service {string}") do |provider_id, service|
  @fhir_claim = build_fhir_claim(patient_id: @case.patient_identifier, service: service, provider: provider_id)
  @claim_response = Corvid::PriorAuthorizationApiService.submit_from_claim(@fhir_claim)
  @referral = Corvid::PrcReferral.find_by!(referral_identifier: @claim_response[:id])
end

Then("a PrcReferral should be created in {string} status") do |status|
  refute_nil @referral
  assert_equal status, @referral.status
end

Then("a PrcReferral should be created") do
  refute_nil @referral
end

Then("the PrcReferral should record the requesting provider as {string}") do |provider_id|
  ref = Corvid.adapter.find_referral(@referral.referral_identifier)
  refute_nil ref, "Expected adapter to know the referral"
  assert_equal provider_id, ref.requesting_provider_identifier
end

Then("the FHIR response should be a ClaimResponse with outcome {string}") do |outcome|
  assert_equal "ClaimResponse", @claim_response[:resourceType]
  assert_equal outcome, @claim_response[:outcome]
end

Then("the ClaimResponse should reference the new PrcReferral") do
  assert_equal @referral.referral_identifier, @claim_response[:id]
end

Given("an authorized PRC referral {string} exists") do |identifier|
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: identifier,
    facility_identifier: @facility,
    status: "authorized",
    authorization_number: "AUTH-#{identifier}"
  )
end

Given("a denied PRC referral {string} exists with reason {string}") do |identifier, reason|
  reason_token = Corvid.adapter.store_text(
    case_token: @case.id.to_s, kind: :reason, text: reason
  )
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: identifier,
    facility_identifier: @facility,
    status: "denied",
    deferred_reason_token: reason_token
  )
  @referral.record_determination!(
    outcome: "denied",
    decision_method: "staff_review",
    reasons: [ reason ],
    determined_by_identifier: "pr_reviewer_001"
  )
end

Given("a pending PRC referral {string} exists in {string} state") do |identifier, state|
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: identifier,
    facility_identifier: @facility,
    status: state
  )
end

Given("a PRC referral {string} exists") do |identifier|
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: identifier,
    facility_identifier: @facility,
    status: "submitted"
  )
end

When("I retrieve the ClaimResponse for {string}") do |identifier|
  ref = Corvid::PrcReferral.find_by!(referral_identifier: identifier)
  @claim_response = Corvid::PriorAuthorizationApiService.claim_response_for(ref)
end

Then("the ClaimResponse outcome should be {string}") do |outcome|
  assert_equal outcome, @claim_response[:outcome]
end

Then("the ClaimResponse disposition should be {string}") do |disposition|
  assert_equal disposition, @claim_response[:disposition]
end

Then("the ClaimResponse should include the denial reason") do
  notes = @claim_response[:processNote]
  refute_nil notes, "Expected processNote with denial reason"
  assert notes.any? { |n| n[:text].to_s.length > 0 }, "Expected non-empty denial text"
end

Given("the following PRC referrals exist for patient {string}:") do |patient_id, table|
  kase = Corvid::Case.find_or_create_by!(
    patient_identifier: patient_id,
    facility_identifier: @facility
  )
  table.hashes.each do |row|
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: row["identifier"],
      facility_identifier: @facility,
      status: row["status"]
    )
  end
end

When("I request all ClaimResponses for patient {string}") do |patient_id|
  @bundle = Corvid::PriorAuthorizationApiService.bundle_for_patient(patient_id)
end

Then("the Bundle should contain {int} ClaimResponse entries") do |count|
  assert_equal "Bundle", @bundle[:resourceType]
  assert_equal count, @bundle[:entry].size
  @bundle[:entry].each do |entry|
    assert_equal "ClaimResponse", entry[:resource][:resourceType]
  end
end

When("I request the list of covered items and services") do
  @covered = Corvid::PriorAuthorizationApiService.covered_services
end

Then("the response should list service categories requiring prior authorization") do
  assert_equal "Bundle", @covered[:resourceType]
  assert @covered[:entry].any?, "Expected at least one covered service"
  @covered[:entry].each do |entry|
    assert_equal "ActivityDefinition", entry[:resource][:resourceType]
  end
end

When("I request documentation requirements for service {string}") do |service|
  @questionnaire = Corvid::PriorAuthorizationApiService.documentation_requirements_for(service)
end

Then("the response should list required clinical documentation") do
  assert_equal "Questionnaire", @questionnaire[:resourceType]
  assert @questionnaire[:item].any? { |i| i[:required] }, "Expected at least one required item"
end

When("the referral is pended for additional clinical documentation") do
  @referral.update!(flagged_for_review: true)
end

Then("the ClaimResponse should list required additional information") do
  assert_equal "pended", @claim_response[:disposition]
  refute_nil @claim_response[:processNote]
  assert @claim_response[:processNote].any? { |n| n[:text].to_s.length > 0 }
end
