# frozen_string_literal: true

# Alternate resource step definitions (ported from rpms_redux)

When("I create an alternate resource check for {string}") do |resource_type|
  @check = Corvid::AlternateResourceCheck.create!(
    prc_referral: @referral,
    resource_type: resource_type
  )
end

When("I create an alternate resource check for {string} with status {string}") do |resource_type, status|
  @check = Corvid::AlternateResourceCheck.create!(
    prc_referral: @referral,
    resource_type: resource_type,
    status: status
  )
end

Given("the following alternate resource checks exist:") do |table|
  table.hashes.each do |row|
    Corvid::AlternateResourceCheck.create!(
      prc_referral: @referral,
      resource_type: row["resource_type"],
      status: row["status"]
    )
  end
end

Given("an alternate resource check for {string} already exists") do |resource_type|
  Corvid::AlternateResourceCheck.create!(
    prc_referral: @referral,
    resource_type: resource_type
  )
end

Given("an alternate resource check for {string} exists with status {string}") do |resource_type, status|
  @check = Corvid::AlternateResourceCheck.create!(
    prc_referral: @referral,
    resource_type: resource_type,
    status: status
  )
end

Given("an alternate resource check exists with status {string}") do |status|
  @check = Corvid::AlternateResourceCheck.create!(
    prc_referral: @referral,
    resource_type: "medicare_a",
    status: status
  )
end

Given("the check was verified {int} days ago") do |days|
  @check.update!(checked_at: days.days.ago)
end

When("I try to create another check for {string}") do |resource_type|
  @check = Corvid::AlternateResourceCheck.new(
    prc_referral: @referral,
    resource_type: resource_type
  )
  @check.valid?
end

When("I check if alternate resources are exhausted") do
  @all_exhausted = Corvid::AlternateResourceCheck.all_exhausted?(@referral)
end

When("I record private insurance coverage with:") do |table|
  row = table.rows_hash
  @check = Corvid::AlternateResourceCheck.create!(
    prc_referral: @referral,
    resource_type: "private_insurance",
    status: :enrolled,
    payer_token: Corvid.adapter.store_text(case_token: "ct_x", kind: :payer, text: row["payer_name"]),
    policy_token: Corvid.adapter.store_text(case_token: "ct_x", kind: :policy, text: row["policy_number"]),
    group_number: row["group_number"],
    coverage_start: Date.parse(row["coverage_start"]),
    coverage_end: Date.parse(row["coverage_end"])
  )
end

When("I filter for federal programs") do
  @filtered = @referral.alternate_resource_checks.federal
end

When("I filter for private payers") do
  @filtered = @referral.alternate_resource_checks.private_payer
end

When("I verify the enrollment status") do
  @check.verify!
  @check.reload
end

When("I verify all enrollment statuses for the referral") do
  Corvid::AlternateResourceCheck.verify_all_for_referral(@referral)
  @referral.alternate_resource_checks.reload
end

When("I create all resource checks for the referral") do
  Corvid::AlternateResourceCheck.create_all_for_referral(@referral)
end

When("I check if the verification is stale") do
  @is_stale = @check.stale?
end

Then("an alternate resource check for {string} should exist") do |resource_type|
  check = @referral.alternate_resource_checks.find_by(resource_type: resource_type)
  refute_nil check, "Expected alternate resource check for #{resource_type}"
end

Then("the check status should be {string}") do |status|
  @check.reload
  assert_equal status, @check.status
end

Then("the check status should not be {string}") do |status|
  @check.reload
  refute_equal status, @check.status
end

Then("the check should indicate active coverage") do
  @check.reload
  assert @check.enrolled? || @check.pending_enrollment?
end

Then("all resources should be exhausted") do
  assert @all_exhausted, "Expected all resources to be exhausted"
end

Then("all resources should not be exhausted") do
  refute @all_exhausted, "Expected not all resources to be exhausted"
end

Then("there should be pending resource checks") do
  assert Corvid::AlternateResourceCheck.any_pending?(@referral)
end

Then("the payer name should be {string}") do |name|
  text = Corvid.adapter.fetch_text(@check.payer_token)
  assert_equal name, text
end

Then("the policy number should be {string}") do |number|
  text = Corvid.adapter.fetch_text(@check.policy_token)
  assert_equal number, text
end

Then("the resource name should be {string}") do |name|
  assert_equal name, @check.resource_name
end

Then("the check should be invalid") do
  refute @check.valid?
end

Then("I should see an error about duplicate resource type") do
  assert @check.errors[:resource_type].any?
end

Then("the check should require coordination of benefits") do
  assert @check.requires_coordination?
end

Then("the check should not require coordination of benefits") do
  refute @check.requires_coordination?
end

Then("I should see {int} checks") do |count|
  assert_equal count, @filtered.count
end

Then("I should not see {string}") do |resource_type|
  refute @filtered.pluck(:resource_type).include?(resource_type)
end

Then("the check should have response data") do
  @check.reload
  refute_nil @check.checked_at
end

Then("all checks should have been verified") do
  @referral.alternate_resource_checks.reload.each do |check|
    refute_equal "not_checked", check.status, "Check #{check.resource_type} was not verified"
  end
end

Then("alternate resource checks should exist for all resource types") do
  types = @referral.alternate_resource_checks.pluck(:resource_type)
  Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
    assert_includes types, type, "Missing check for #{type}"
  end
end

Then("the verification should be stale") do
  assert @is_stale
end

Then("the verification should not be stale") do
  refute @is_stale
end
