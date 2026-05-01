# frozen_string_literal: true

# Authorization workflow step definitions (extended scenarios)

Given("the referral has been submitted") do
  @referral.submit!
end

Given("the referral has been authorized") do
  @referral.authorize!
end

Given("the referral is in priority assignment with low cost") do
  @referral.submit!
  @referral.begin_eligibility_review!
  @referral.reload
  checklist_for(@referral) do |c|
    c.update!(
      application_complete: true, identity_verified: true,
      insurance_verified: true, residency_verified: true,
      enrollment_verified: true, clinical_necessity_documented: true
    )
  end
  @referral.reload
  @referral.request_management_approval!
  @referral.pending_approval_by = "pr_test_mgr"
  @referral.approve_management!
  @referral.verify_alternate_resources!
  @referral.update!(estimated_cost: 5_000)
  assert_equal "priority_assignment", @referral.status
end

Given("the referral is in priority assignment with high cost") do
  @referral.submit!
  @referral.begin_eligibility_review!
  @referral.reload
  checklist_for(@referral) do |c|
    c.update!(
      application_complete: true, identity_verified: true,
      insurance_verified: true, residency_verified: true,
      enrollment_verified: true, clinical_necessity_documented: true
    )
  end
  @referral.reload
  @referral.request_management_approval!
  @referral.pending_approval_by = "pr_test_mgr"
  @referral.approve_management!
  @referral.verify_alternate_resources!
  @referral.update!(estimated_cost: 100_000)
  assert_equal "priority_assignment", @referral.status
end

Given("the referral is in eligibility review") do
  @referral.submit!
  @referral.begin_eligibility_review!
  assert_equal "eligibility_review", @referral.status
end

When("the referral is deferred") do
  @referral.mark_deferred!
end

When("the referral is cancelled") do
  @referral.cancel!
end

When("the referral is authorized") do
  @referral.authorize!
end

When("the referral is denied") do
  @referral.mark_denied!
end

When("priority assignment completes") do
  @referral.complete_priority_assignment!
end

Then("a determination should be recorded with outcome {string}") do |outcome|
  @referral.reload
  determination = @referral.determinations.last
  refute_nil determination, "Expected a determination to be recorded"
  assert_equal outcome, determination.outcome
end
