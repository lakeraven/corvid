# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 pin 1: status polls may record "submitted" (and other
# sent statuses) on a linked claim that was actually sent, without raising.
class Corvid::ClaimSubmissionCheckStatusSubmittedPollTest < ActiveSupport::TestCase
  TENANT = "tnt_chk_sub_poll"
  FACILITY = "fac_chk_sub_poll"
  POLL_AT = Time.zone.parse("2025-07-01 12:00:00 UTC")

  test "check_status! records submitted when adapter error claim with identifier is polled submitted" do
    with_tenant(TENANT) do
      travel_to POLL_AT do
        claim = linked_claim_sent_with_adapter_error!("REF-POLL-SUB-ERR", "CLM-POLL-SUB-ERR")
        Corvid.adapter.add_claim("CLM-POLL-SUB-ERR", { status: "submitted" })

        assert_nothing_raised { claim.check_status! }

        claim.reload
        assert_equal "submitted", claim.status
        assert_equal POLL_AT, claim.last_checked_at
      end
    end
  end

  test "check_status! records submitted when accepted claim is polled submitted" do
    with_tenant(TENANT) do
      travel_to POLL_AT do
        claim = linked_claim_sent_with_adapter_error!("REF-POLL-SUB-ACC", "CLM-POLL-SUB-ACC")
        claim.update_columns(status: "accepted")
        claim.reload
        Corvid.adapter.add_claim("CLM-POLL-SUB-ACC", { status: "submitted" })

        assert_nothing_raised { claim.check_status! }

        claim.reload
        assert_equal "submitted", claim.status
        assert_equal POLL_AT, claim.last_checked_at
      end
    end
  end

  private

  def referral_at(identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_#{identifier}",
      facility_identifier: FACILITY
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: FACILITY,
      tenant_identifier: TENANT
    )
  end

  def authorize!(referral)
    referral.submit!
    referral.begin_eligibility_review!
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
    referral.pending_approval_by = "usr_other"
    referral.approve_management!
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.complete_priority_assignment!
    referral.authorize! if referral.may_authorize?
    referral.reload
  end

  def build_claim(referral_identifier:, patient:)
    Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT,
      facility_identifier: FACILITY,
      patient_identifier: patient,
      referral_identifier: referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 15),
      billed_amount: 100.0,
      status: "draft"
    )
  end

  def linked_claim_sent_with_adapter_error!(referral_identifier, claim_identifier)
    referral = referral_at(referral_identifier)
    patient = referral.case.patient_identifier
    authorize!(referral)
    claim = build_claim(referral_identifier: referral_identifier, patient: patient)
    claim.save!
    claim.update_columns(
      status: "error",
      claim_identifier: claim_identifier,
      submitted_at: POLL_AT - 1.hour
    )
    claim.reload
  end
end
