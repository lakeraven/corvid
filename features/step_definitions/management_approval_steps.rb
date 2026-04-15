# frozen_string_literal: true

Given("the referral is in {string} status") do |status|
  case status
  when "eligibility_review"
    @referral.submit!
    @referral.begin_eligibility_review!
  when "management_approval"
    @referral.submit!
    @referral.begin_eligibility_review!
    @checklist = checklist_for(@referral) do |c|
      c.update!(
        application_complete: true,
        identity_verified: true,
        insurance_verified: true,
        residency_verified: true,
        enrollment_verified: true,
        clinical_necessity_documented: true,
        management_approved: false
      )
    end
    @referral.reload
    @referral.request_management_approval!
  end
  assert_equal status, @referral.status
end

Given("an eligibility checklist with all non-approval items complete") do
  @checklist = checklist_for(@referral) do |c|
    c.update!(
      application_complete: true,
      identity_verified: true,
      insurance_verified: true,
      residency_verified: true,
      enrollment_verified: true,
      clinical_necessity_documented: true,
      management_approved: false
    )
  end
end

Given("an eligibility checklist with only {int} items complete") do |count|
  @checklist = checklist_for(@referral) do |c|
    c.update!(
      application_complete: count >= 1,
      identity_verified: count >= 2,
      insurance_verified: count >= 3,
      residency_verified: false,
      enrollment_verified: false,
      clinical_necessity_documented: false,
      management_approved: false
    )
  end
end

When("I try to advance directly to alternate resource review") do
  direct_events = @referral.class.aasm.events.select do |event|
    event.transitions.any? do |t|
      Array(t.from).include?(:eligibility_review) &&
        t.to == :alternate_resource_review
    end
  end
  assert_empty direct_events.map(&:name),
    "Expected no direct path from eligibility_review to alternate_resource_review"
end

When("I request management approval") do
  @referral.reload
  @referral.request_management_approval! if @referral.may_request_management_approval?
end

When("manager {string} approves the referral") do |manager_id|
  @referral.pending_approval_by = manager_id
  @referral.approve_management!
end

Then("the referral should be in {string} status") do |status|
  assert_equal status, @referral.status
end

Then("the referral should remain in {string} status") do |status|
  assert_equal status, @referral.status
end

Then("the eligibility checklist should have management approval by {string}") do |manager_id|
  @checklist.reload
  assert @checklist.management_approved
  assert_equal manager_id, @checklist.management_approved_by
end

Then("the eligibility checklist should be complete") do
  @checklist.reload
  assert @checklist.complete?, "Expected checklist to be complete but missing: #{@checklist.missing_items}"
end
