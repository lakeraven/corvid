# frozen_string_literal: true

require "active_support/testing/time_helpers"

World(ActiveSupport::Testing::TimeHelpers)

Given("a held draft claim exists for patient {string} with a medicaid hold override") do |patient_id|
  travel_to Time.zone.local(2026, 8, 1, 12, 0, 0) do
    kase = Corvid::Case.create!(
      patient_identifier: patient_id,
      facility_identifier: @facility
    )
    @referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "REF-MCA-HOLD-#{SecureRandom.hex(3)}",
      facility_identifier: @facility
    )
    authorize_referral_for_medicaid_hold!(@referral)
    medicaid = @referral.alternate_resource_checks.find_or_create_by!(resource_type: "medicaid") do |check|
      check.status = "not_checked"
    end
    medicaid.update!(
      status: "pending_enrollment",
      application_date: Date.new(2026, 3, 15),
      application_date_source: "staff_entry",
      medicaid_state_code: "XA",
      eligibility_group: "expansion_adult",
      eligibility_group_source: "staff_entry",
      eligibility_group_set_at: Time.current
    )
    @claim = Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: patient_id,
      referral_identifier: @referral.referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2026, 2, 1),
      billed_amount: 100.0,
      status: "draft"
    )
    @claim.override_medicaid_hold!(
      reason_token: "rt_medicaid_hold_override",
      by_identifier: "usr_billing_cuke"
    )
    @claim.reload
    @submit_calls = []
    submit_calls = @submit_calls
    Corvid.adapter.define_singleton_method(:submit_claim) do |data|
      submit_calls << data
      { claim_identifier: "CLM-CUKE-001", status: "accepted" }
    end
  end
end

Given("another patient has a pending in-window medicaid application") do
  @other_patient_id = "pt-mca-hold-cuke-#{SecureRandom.hex(2)}"
  other_case = Corvid::Case.create!(
    patient_identifier: @other_patient_id,
    facility_identifier: @facility
  )
  other_referral = Corvid::PrcReferral.create!(
    case: other_case,
    referral_identifier: "REF-OTHER-MCA-#{SecureRandom.hex(2)}",
    facility_identifier: @facility
  )
  medicaid = other_referral.alternate_resource_checks.find_or_create_by!(resource_type: "medicaid") do |check|
    check.status = "not_checked"
  end
  medicaid.update!(
    status: "pending_enrollment",
    application_date: Date.new(2026, 3, 15),
    application_date_source: "staff_entry",
    medicaid_state_code: "XA",
    eligibility_group: "expansion_adult",
    eligibility_group_source: "staff_entry",
    eligibility_group_set_at: Time.current
  )
end

When("I assign the claim to that patient without saving") do
  @claim.patient_identifier = @other_patient_id
end

When("I attempt to submit the held claim") do
  travel_to Time.zone.local(2026, 8, 1, 12, 0, 0) do
    @submit_error = nil
    begin
      @claim.submit!
    rescue Corvid::ClaimSubmission::HeldForPendingMedicaid => error
      @submit_error = error
    end
  end
end

Then("the claim submit should be refused for pending medicaid") do
  assert_instance_of Corvid::ClaimSubmission::HeldForPendingMedicaid, @submit_error
  assert_equal "window_undetermined", @submit_error.reason
  @claim.reload
  assert_equal "draft", @claim.status
  assert_nil @claim.submitted_at
  assert @claim.medicaid_hold_override_reason_token.present?
end

Then("the clearinghouse should receive no claim submissions") do
  assert_empty @submit_calls
end

def authorize_referral_for_medicaid_hold!(referral)
  referral.submit!
  referral.begin_eligibility_review!
  referral.reload
  checklist = referral.eligibility_checklist
  Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
    fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
    kwargs = {}
    kwargs[:source] = "test_fixture" if fields.key?(:source)
    kwargs[:by] = "usr_submitter" if fields.key?(:by)
    checklist.verify_item!(item, **kwargs)
  end
  referral.reload
  referral.request_management_approval!
  referral.pending_approval_by = "usr_other_approver"
  referral.approve_management!
  referral.reload
  exhaust_alternate_resources!(referral)
  referral.verify_alternate_resources!
  referral.reload
  exhaust_alternate_resources!(referral)
  referral.complete_priority_assignment!
  referral.reload
  referral.authorize! if referral.may_authorize? && !referral.committee_review?
  referral.reload
end
