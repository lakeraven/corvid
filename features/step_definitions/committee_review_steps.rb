# frozen_string_literal: true

Given("the referral estimated cost is {string}") do |cost|
  @referral.update!(estimated_cost: cost.delete("$,").to_f)
end

Given("the referral has medical priority {int}") do |priority|
  @referral.update!(medical_priority: priority)
end

Given("the referral is flagged for review") do
  @referral.update!(flagged_for_review: true)
end

When("I schedule a committee review for today") do
  @review = Corvid::CommitteeReview.create!(
    prc_referral: @referral,
    committee_date: Date.current
  )
end

Then("a committee review should exist") do
  assert @review.persisted?
end

Then("the review decision should be {string}") do |decision|
  assert_equal decision, @review.reload.decision
end

Given("a pending committee review exists") do
  @review = Corvid::CommitteeReview.create!(
    prc_referral: @referral,
    committee_date: Date.current
  )
end

When("the committee approves with amount {string}") do |amount|
  @review.update!(decision: :approved, approved_amount: amount.delete("$,").to_f)
end

When("the committee denies the referral") do
  @review.denied!
end

When("the committee defers the decision") do
  @review.deferred!
end

When("the committee modifies with amount {string}") do |amount|
  @review.update!(decision: :modified, approved_amount: amount.delete("$,").to_f)
end

Then("the review should not be finalized") do
  refute @review.finalized?
end

Then("the review should be finalized") do
  assert @review.finalized?
end

Given("the referral is in committee_review state") do
  @referral.update_column(:status, "committee_review")
  @referral.reload
end

When("I apply the review to the referral") do
  @review.apply_to_referral!
end

Then("the PRC referral status should be {string}") do |status|
  assert_equal status, @referral.reload.status
end

Given("the referral is registered with the adapter") do
  adapter = Corvid.adapter
  adapter.instance_variable_get(:@referrals)[@referral.referral_identifier] = {
    patient_identifier: @referral.case.patient_identifier,
    status: "pending"
  }
end

When("the decision is synced to EHR") do
  @sync_result = Corvid::CommitteeReviewSyncService.sync_decision(@review)
end

Then("the sync should be successful") do
  assert @sync_result[:success], "Expected sync to succeed but got: #{@sync_result}"
end

When("I attempt to sync the pending decision to EHR") do
  @sync_result = Corvid::CommitteeReviewSyncService.sync_decision(@review)
end

Then("the sync should fail with {string}") do |error|
  refute @sync_result[:success]
  assert_equal error, @sync_result[:error]
end
