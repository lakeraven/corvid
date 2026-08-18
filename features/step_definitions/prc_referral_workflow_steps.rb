# frozen_string_literal: true

# Staff-facing steps for features/prc/prc_referral_state_machine.feature.
# Phrased as what PRC staff (Referral Specialist, PRC Director) actually do,
# and what the program cannot do out of order. Tenant/patient/referral setup
# is reused from the eligibility-checklist step definitions.

REFERRAL_STATE_PHRASES = {
  "in draft" => "draft",
  "submitted" => "submitted",
  "under eligibility review" => "eligibility_review",
  "awaiting management approval" => "management_approval",
  "in alternate-resource review" => "alternate_resource_review",
  "in priority assignment" => "priority_assignment",
  "before the review committee" => "committee_review",
  "authorized" => "authorized",
  "denied" => "denied",
  "deferred" => "deferred",
  "cancelled" => "cancelled"
}.freeze

def referral_state_for(phrase)
  REFERRAL_STATE_PHRASES.fetch(phrase) { raise "unknown referral state phrase: #{phrase.inspect}" }
end

# -- staff actions -----------------------------------------------------------

Given("the referral was submitted by the Referral Specialist {string}") do |specialist|
  @referral.update_columns(submitted_by_identifier: specialist)
end

When("the Referral Specialist submits the referral") do
  @referral.submit!
  @referral.reload
end

When("the Referral Specialist begins eligibility review") do
  @referral.begin_eligibility_review!
  @referral.reload
end

When("the eligibility documentation is complete") do
  checklist_for(@referral) do |c|
    c.update!(
      application_complete: true, identity_verified: true, insurance_verified: true,
      residency_verified: true, enrollment_verified: true, clinical_necessity_documented: true,
      management_approved: false
    )
  end
  @referral.reload
end

Given("the eligibility documentation is incomplete") do
  checklist_for(@referral) do |c|
    c.update!(
      application_complete: true, identity_verified: true, insurance_verified: false,
      residency_verified: false, enrollment_verified: false, clinical_necessity_documented: false,
      management_approved: false
    )
  end
  @referral.reload
end

When("the Referral Specialist requests management approval") do
  @referral.request_management_approval!
  @referral.reload
end

When("the PRC Director {string} approves the referral") do |director|
  @referral.pending_approval_by = director
  @referral.approve_management!
  @referral.reload
end

When("the Referral Specialist verifies alternate resources") do
  @referral.verify_alternate_resources!
  @referral.reload
end

When("the Referral Specialist completes priority assignment") do
  @referral.complete_priority_assignment!
  @referral.reload
end

When("the committee authorizes the referral") do
  @referral.authorize!
  @referral.reload
end

When("the PRC program denies the referral") do
  @referral.mark_denied!
  @referral.reload
end

When("the PRC program defers the referral") do
  @referral.mark_deferred!
  @referral.reload
end

# -- state / setup -----------------------------------------------------------

Then("the referral should be {string}") do |phrase|
  assert_equal referral_state_for(phrase), @referral.reload.status
end

Given("the referral is {string}") do |phrase|
  target = referral_state_for(phrase)
  @referral.submit! if target != "draft"
  @referral.begin_eligibility_review! if %w[eligibility_review].include?(target)
  @referral.reload
  assert_equal target, @referral.status, "could not set up referral in #{phrase}"
end

Given("the referral has reached {string}") do |phrase|
  target = referral_state_for(phrase)
  @referral.update_columns(submitted_by_identifier: "spec_iselda") if @referral.submitted_by_identifier.blank?
  @referral.submit!
  @referral.begin_eligibility_review!
  checklist_for(@referral) do |c|
    c.update!(
      application_complete: true, identity_verified: true, insurance_verified: true,
      residency_verified: true, enrollment_verified: true, clinical_necessity_documented: true,
      management_approved: false
    )
  end
  @referral.reload
  @referral.request_management_approval!
  unless target == "management_approval"
    @referral.pending_approval_by = "dir_cookie"
    @referral.approve_management!
    @referral.verify_alternate_resources! unless target == "alternate_resource_review"
  end
  @referral.reload
  assert_equal target, @referral.status, "expected to reach #{phrase}, got #{@referral.status}"
end

When("the PRC Director {string} returns the referral for correction") do |director|
  @referral.rejecting_by = director
  @referral.rejection_reason = "Documentation incomplete — please correct and resubmit"
  @referral.reject_management!
  @referral.reload
end

When("an eligibility item is withdrawn after approval") do
  checklist_for(@referral).unverify_item!(:residency_verified)
  @referral.reload
end

When("the Referral Specialist cancels the referral") do
  @referral.cancel!
  @referral.reload
end

Then("the referral is not yet approved") do
  checklist = @referral.reload.eligibility_checklist
  refute checklist&.management_approved, "expected the referral to NOT be approved, but it was"
end

Given("the referral requires committee review") do
  @referral.update_columns(flagged_for_review: true)
  @referral.reload
end

Given("the referral does not require committee review") do
  @referral.update_columns(flagged_for_review: false, medical_priority: 2)
  @referral.reload
end

# -- guard-enforced "cannot" rules (what the program is not allowed to do) ----

Then("the PRC program cannot authorize the referral") do
  @referral.reload
  refute @referral.may_authorize?, "the program should not be able to authorize from #{@referral.status}"
end

Then("the PRC Director cannot yet approve the referral") do
  @referral.reload
  refute @referral.may_approve_management?, "the Director should not be able to approve from #{@referral.status}"
end

Then("the Referral Specialist cannot request management approval") do
  @referral.reload
  refute @referral.may_request_management_approval?,
    "approval should not be requestable from #{@referral.status} with an incomplete file"
end

Then("the Referral Specialist cannot complete priority assignment") do
  @referral.reload
  refute @referral.may_complete_priority_assignment?,
    "priority assignment should not be completable from #{@referral.status}"
end

Then("the Referral Specialist cannot re-submit the referral") do
  @referral.reload
  refute @referral.may_submit?, "a #{@referral.status} referral should not be re-submittable"
end
