# frozen_string_literal: true

Given("the adapter cannot re-verify {string} eligibility") do |resource_type|
  patient_id = @referral.case.patient_identifier
  Corvid.adapter.define_singleton_method(:verify_eligibility) do |pid, type|
    raise "unreadable" if pid == patient_id && type == resource_type

    { eligible: false }
  end
end

When("committee sync is attempted for the approved review") do
  @committee_review ||= Corvid::CommitteeReview.find_by!(prc_referral: @referral)
  @recording_adapter = Class.new do
    def update_referral(_identifier, _params)
      true
    end

    def fetch_text(_token)
      ""
    end
  end.new
  @committee_sync_result = Corvid::CommitteeReviewSyncService.sync_decision(
    @committee_review,
    adapter: @recording_adapter
  )
end

Then("the sync should be blocked with blocker {string}") do |blocker|
  refute @committee_sync_result[:success]
  assert @committee_sync_result[:blocked]
  assert_includes @committee_sync_result[:blockers], blocker
end

Then("the sync blockers should not be only {string}") do |only_blocker|
  refute_equal [ only_blocker ], @committee_sync_result[:blockers]
end

Given("an authorized PRC referral {string} for patient {string}") do |identifier, patient_id|
  @case = Corvid::Case.create!(
    patient_identifier: patient_id,
    facility_identifier: @facility,
    lifecycle_status: "intake"
  )
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: identifier,
    facility_identifier: @facility
  )
  Corvid.adapter.add_referral(
    identifier,
    patient_identifier: patient_id,
    status: "pending",
    estimated_cost: 5_000,
    service_requested: "TEST"
  )
  @referral.submit!
  @referral.begin_eligibility_review!
  checklist_for(@referral) do |c|
    c.update!(
      application_complete: true, identity_verified: true, insurance_verified: true,
      residency_verified: true, enrollment_verified: true, clinical_necessity_documented: true
    )
  end
  @referral.reload
  @referral.request_management_approval!
  @referral.pending_approval_by = "dir_gate_test"
  @referral.approve_management!
  exhaust_alternate_resources!(@referral)
  @referral.verify_alternate_resources!
  @referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
  exhaust_alternate_resources!(@referral)
  @referral.complete_priority_assignment!
  @referral.authorize! if @referral.may_authorize?
  assert_equal "authorized", @referral.reload.status
end

Given("a draft claim linked to that referral with service date {string}") do |iso_date|
  @claim = Corvid::ClaimSubmission.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: @case.patient_identifier,
    referral_identifier: @referral.referral_identifier,
    claim_type: "professional",
    service_date: Date.parse(iso_date),
    billed_amount: 100.0,
    status: "draft"
  )
  assert_equal @referral.id, @claim.reload.prc_referral_id
end

When("the billing coordinator updates the claim status to {string} without submit!") do |status|
  @claim.status = status
  @claim_update_result = @claim.save
end

Then("the claim update should be rejected") do
  refute @claim_update_result
  assert_predicate @claim.errors[:status], :present?
end

Then("the claim should remain in draft with no submitted_at") do
  assert_equal "draft", @claim.reload.status
  assert_nil @claim.submitted_at
end
