# frozen_string_literal: true

# Committee sync step definitions (ported from rpms_redux)

Given("the referral is in committee review state") do
  # Seed adapter with the referral so sync_status_to_ehr can update it
  Corvid.adapter.add_referral(@referral.referral_identifier,
    patient_identifier: @case.patient_identifier,
    status: "pending", estimated_cost: 100_000,
    chs_approval_status: "P"
  )
  @referral.submit!
  @referral.begin_eligibility_review!
  # Set up checklist and advance through management approval
  @referral.reload
  checklist = checklist_for(@referral) do |c|
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
  # Force into committee review (need high cost or flagged)
  @referral.update!(estimated_cost: 100_000)
  @referral.complete_priority_assignment!
  assert_equal "committee_review", @referral.status
end

When("a committee review approves the referral for {int}") do |amount|
  Corvid::CommitteeReview.create!(
    prc_referral: @referral,
    tenant_identifier: @referral.tenant_identifier,
    facility_identifier: @referral.facility_identifier,
    decision: :approved,
    approved_amount: amount,
    committee_date: Date.current
  )
  @referral.authorize!
end

When("alternate resource checks are created for all resource types") do
  Corvid::AlternateResourceCheck.create_all_for_referral(@referral)
end

When("all checks are verified via the adapter") do
  Corvid::AlternateResourceCheck.verify_all_for_referral(@referral)
end

Then("the adapter should have the referral updated with approval status") do
  ref = Corvid.adapter.find_referral(@referral.referral_identifier)
  assert_equal "A", ref.chs_approval_status
end

Then("each check should have a status of enrolled or not_enrolled") do
  @referral.alternate_resource_checks.reload.each do |check|
    assert %w[enrolled not_enrolled].include?(check.status),
      "Check #{check.resource_type} has status #{check.status}, expected enrolled or not_enrolled"
  end
end
