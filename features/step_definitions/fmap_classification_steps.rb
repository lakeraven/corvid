# frozen_string_literal: true

Given("a tenant {string} with the default FMAP rule set loaded") do |tenant|
  @tenant = tenant
  Corvid::TenantContext.current_tenant_identifier = tenant
  Corvid::FmapRuleLoader.load_defaults!
end

Given("a facility {string} holding a {string} facility authority") do |facility, authority_type|
  @facility_authorities ||= {}
  @facility_authorities[facility] = Corvid::FacilityAuthority.create!(
    facility_identifier: facility,
    authority_type: authority_type,
    air_eligible: true,
    effective_on: Date.new(2020, 1, 1)
  )
end

When("an encounter at {string} with date of service {string} is classified for FMAP") do |facility, dos|
  @determination = Corvid::FmapClassificationService.classify!(
    encounter_identifier: "enc_#{facility}_#{dos}",
    facility_identifier: facility,
    date_of_service: Date.parse(dos),
    jurisdiction: "AZ",
    facility_authority: @facility_authorities.fetch(facility),
    aian_verified: true,
    evidence_refs: [ "attestation:tok_example_aian" ]
  )
end

When("an unverified-AIAN encounter at {string} with date of service {string} is classified for FMAP") do |facility, dos|
  @determination = Corvid::FmapClassificationService.classify!(
    encounter_identifier: "enc_#{facility}_#{dos}",
    facility_identifier: facility,
    date_of_service: Date.parse(dos),
    jurisdiction: "AZ",
    facility_authority: @facility_authorities.fetch(facility),
    aian_verified: false
  )
end

When("an encounter at {string} with date of service {string} is classified and referenced by claim {string}") do |facility, dos, claim|
  @determination = Corvid::FmapClassificationService.classify!(
    encounter_identifier: "enc_#{facility}_#{dos}",
    facility_identifier: facility,
    date_of_service: Date.parse(dos),
    jurisdiction: "AZ",
    facility_authority: @facility_authorities.fetch(facility),
    aian_verified: true,
    claim_reference: claim
  )
end

Then("the FMAP category is {string}") do |category|
  assert_equal category, @determination.category
end

Then("the applied rule citation includes {string}") do |fragment|
  assert @determination.rule_citations.any? { |citation| citation.include?(fragment) },
         "expected citations #{@determination.rule_citations.inspect} to include #{fragment.inspect}"
end

Then("the best available category is {string}") do |category|
  assert_equal category, @determination.best_available_category
end

Then("the missing evidence includes {string}") do |item|
  assert_includes @determination.missing_evidence, item
end

Then("editing the determination is rejected as immutable") do
  @determination.category = "non_medicaid"
  assert_raises(ActiveRecord::RecordInvalid) { @determination.save! }
  @determination.reload
end

Then("superseding it appends a correction linked from the original") do
  correction = @determination.supersede_with!(category: "fmap_regular", fmap_percent: nil, rule_key: nil)
  assert correction.persisted?
  assert_equal correction.id, @determination.reload.superseded_by_id
  assert_equal "fmap_100_uio", @determination.category
end
