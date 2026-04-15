# frozen_string_literal: true

Given("a tenant {string} with facility {string}") do |tenant, facility|
  @tenant = tenant
  @facility = facility
  Corvid::TenantContext.current_tenant_identifier = tenant
end

Given("a patient {string} with a PRC case") do |patient_id|
  @case = Corvid::Case.create!(
    patient_identifier: patient_id,
    facility_identifier: @facility
  )
end

Given("a PRC referral {string} for that case") do |referral_id|
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: referral_id,
    facility_identifier: @facility
  )
end

When("I create an eligibility checklist for the referral") do
  @checklist = Corvid::EligibilityChecklist.create!(
    prc_referral: @referral,
    facility_identifier: @facility
  )
end

Given("an eligibility checklist for the referral") do
  @checklist = Corvid::EligibilityChecklist.create!(
    prc_referral: @referral,
    facility_identifier: @facility
  )
end

When("I verify {string} with source {string}") do |item, source|
  fields = Corvid::EligibilityChecklist::ITEM_FIELDS[item.to_sym]
  if fields.key?(:source)
    @checklist.verify_item!(item.to_sym, source: source)
  else
    @checklist.verify_item!(item.to_sym, by: source)
  end
end

When("I verify {string} with source {string} by {string}") do |item, source, by|
  @checklist.verify_item!(item.to_sym, by: by)
end

When("all 7 items are verified") do
  @checklist.verify_item!(:application_complete, by: "pr_mgr_001")
  @checklist.verify_item!(:identity_verified, source: "baseroll")
  @checklist.verify_item!(:insurance_verified, source: "manual")
  @checklist.verify_item!(:residency_verified, source: "baseroll")
  @checklist.verify_item!(:enrollment_verified, source: "baseroll")
  @checklist.verify_item!(:clinical_necessity_documented, source: "manual")
  @checklist.verify_item!(:management_approved, by: "pr_mgr_001")
end

Then("the checklist should have {int} of {int} items complete") do |complete, total|
  assert_equal total, Corvid::EligibilityChecklist::ITEMS.size
  completed = Corvid::EligibilityChecklist::ITEMS.count { |item| @checklist.send(item) }
  assert_equal complete, completed
end

Then("the compliance percentage should be {float}") do |expected|
  assert_in_delta expected, @checklist.compliance_percentage, 0.01
end

Then("the checklist should track these items:") do |table|
  expected = table.hashes.map { |h| h["item"].to_sym }
  assert_equal expected.sort, Corvid::EligibilityChecklist::ITEMS.sort
end

Then("{string} should be true") do |item|
  assert @checklist.send(item.to_sym), "Expected #{item} to be true"
end

Then("{string} should have a verification timestamp") do |item|
  fields = Corvid::EligibilityChecklist::ITEM_FIELDS[item.to_sym]
  refute_nil @checklist.send(fields[:at]), "Expected #{fields[:at]} to be set"
end

Then("{string} should have source {string}") do |item, source|
  fields = Corvid::EligibilityChecklist::ITEM_FIELDS[item.to_sym]
  assert_equal source, @checklist.send(fields[:source])
end

Then("{string} should have been completed by {string}") do |item, by|
  fields = Corvid::EligibilityChecklist::ITEM_FIELDS[item.to_sym]
  assert_equal by, @checklist.send(fields[:by])
end

Then("{string} should have been approved by {string}") do |item, by|
  fields = Corvid::EligibilityChecklist::ITEM_FIELDS[item.to_sym]
  assert_equal by, @checklist.send(fields[:by])
end

Then("the checklist should be complete") do
  assert @checklist.complete?, "Expected checklist to be complete"
end

Then("the checklist should not be complete") do
  refute @checklist.complete?, "Expected checklist to not be complete"
end

Then("there should be no missing items") do
  assert_empty @checklist.missing_items
end

Then("the missing items should include {string}") do |item|
  assert_includes @checklist.missing_items, item.to_sym
end

Then("{int} non-approval items should be complete") do |count|
  completed = Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.count { |item| @checklist.send(item) }
  assert_equal count, completed
  assert @checklist.items_except_approval_complete?
end
