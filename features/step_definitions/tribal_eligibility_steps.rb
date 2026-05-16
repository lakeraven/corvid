# frozen_string_literal: true

# Step definitions for tribal eligibility BDD scenarios.

Facility = Struct.new(
  :identifier,
  :contracted_tribe_code,
  :requires_on_reservation_flag,
  :requires_ssn_on_file_flag,
  keyword_init: true
) do
  def requires_on_reservation?
    requires_on_reservation_flag
  end

  def requires_ssn_on_file?
    requires_ssn_on_file_flag
  end
end unless defined?(Facility)

Given("facility {string} has contracted tribe code {string}") do |facility_id, tribe_code|
  @facility_objects ||= {}
  @facility_objects[facility_id] = Facility.new(
    identifier: facility_id,
    contracted_tribe_code: tribe_code,
    requires_on_reservation_flag: false,
    requires_ssn_on_file_flag: false
  )
end

Given("person {string} is enrolled in tribe {string} with confidence {word}") do |person_id, tribe_code, confidence|
  Corvid.adapter.add_enrollment(person_id,
                                enrolled: true,
                                tribe_name: "#{tribe_code} Tribe",
                                tribe_code: tribe_code,
                                member_status: "enrolled",
                                confidence: confidence.to_sym)
end

When("I decide eligibility for person {string} at facility {string}") do |person_id, facility_id|
  facility = @facility_objects[facility_id]
  @decision = Corvid::TribalEligibilityService.decide(
    person_identifier: person_id,
    facility: facility,
    tenant_identifier: @tenant
  )
end

Then("the decision should be eligible") do
  assert @decision.eligible?, "expected eligible; got reasons: #{@decision.reason_codes.inspect}"
end

Then("the decision should be ineligible") do
  refute @decision.eligible?, "expected ineligible; got reasons: #{@decision.reason_codes.inspect}"
end

Then("the reason codes should include {string}") do |code|
  assert_includes @decision.reason_codes.map(&:to_s), code
end

Then("the reason codes should not include any hard-fail reason") do
  intersection = @decision.reason_codes & Corvid::TribalEligibilityService::HARD_FAIL_REASONS
  assert_empty intersection, "unexpected hard-fail reasons: #{intersection.inspect}"
end

Then("exactly {int} PrcEligibilityDecision row should exist for person {string}") do |count, person_id|
  assert_equal count, Corvid::PrcEligibilityDecision.where(person_identifier: person_id).count
end

Then("that row should have the provider confidence {string}") do |confidence|
  row = Corvid::PrcEligibilityDecision.order(decided_at: :desc).first
  assert_equal confidence, row.provider_confidence
end
