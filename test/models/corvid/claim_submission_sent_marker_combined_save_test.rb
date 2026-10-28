# frozen_string_literal: true

require "test_helper"

# Issue #668 pin D: a plain save that combines another attribute change with
# sent markers on a linked never-sent claim is rejected, not accepted with
# markers silently dropped.
class Corvid::ClaimSubmissionSentMarkerCombinedSaveTest < ActiveSupport::TestCase
  TENANT = "tnt_sent_marker"
  FACILITY = "fac_sent_marker"
  PATIENT = "pt_sent_marker"
  SENT_MARKER_MESSAGE = Corvid::ClaimSubmission::SENT_MARKER_MESSAGE

  test "linked error claim save with status change and claim_identifier is rejected" do
    with_tenant(TENANT) do
      claim = linked_unsent_error_claim!

      refute claim.update(status: "error", claim_identifier: "CLM-COMBINED-1")
      assert_includes claim.errors[:claim_identifier], SENT_MARKER_MESSAGE
      claim.reload
      assert_equal "error", claim.status
      assert_nil claim.claim_identifier
    end
  end

  test "linked error claim save with status change and submitted_at is rejected" do
    with_tenant(TENANT) do
      claim = linked_unsent_error_claim!

      refute claim.update(status: "error", submitted_at: 1.hour.ago)
      assert claim.errors[:submitted_at].present? || claim.errors[:claim_identifier].present?
      claim.reload
      assert_equal "error", claim.status
      assert_nil claim.submitted_at
    end
  end

  test "linked error claim update! with status change and claim_identifier raises" do
    with_tenant(TENANT) do
      claim = linked_unsent_error_claim!

      error = assert_raises(ActiveRecord::RecordInvalid) do
        claim.update!(status: "error", claim_identifier: "CLM-COMBINED-2")
      end
      assert_includes error.record.errors[:claim_identifier], SENT_MARKER_MESSAGE
      assert_nil claim.reload.claim_identifier
    end
  end

  test "linked draft claim save with status change and claim_identifier is rejected" do
    with_tenant(TENANT) do
      claim = linked_unsent_draft_claim!

      refute claim.update(status: "error", claim_identifier: "CLM-DRAFT-COMBINED-1")
      assert_includes claim.errors[:claim_identifier], SENT_MARKER_MESSAGE
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.claim_identifier
    end
  end

  test "linked draft claim save with status change and submitted_at is rejected" do
    with_tenant(TENANT) do
      claim = linked_unsent_draft_claim!

      refute claim.update(status: "error", submitted_at: 1.hour.ago)
      assert claim.errors[:submitted_at].present? || claim.errors[:claim_identifier].present?
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
    end
  end

  test "linked draft claim update! with status change and claim_identifier raises" do
    with_tenant(TENANT) do
      claim = linked_unsent_draft_claim!

      error = assert_raises(ActiveRecord::RecordInvalid) do
        claim.update!(status: "error", claim_identifier: "CLM-DRAFT-COMBINED-2")
      end
      assert_includes error.record.errors[:claim_identifier], SENT_MARKER_MESSAGE
      assert_nil claim.reload.claim_identifier
    end
  end

  private

  def linked_unsent_error_claim!
    referral = referral_at
    claim = Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT,
      facility_identifier: FACILITY,
      patient_identifier: PATIENT,
      referral_identifier: referral.referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 10),
      billed_amount: 100.0,
      status: "draft"
    )
    claim.save!
    claim.update_column(:status, "error")
    claim.reload
  end

  def linked_unsent_draft_claim!
    referral = referral_at
    authorize_referral!(referral)
    claim = Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT,
      facility_identifier: FACILITY,
      patient_identifier: PATIENT,
      referral_identifier: referral.referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 10),
      billed_amount: 100.0,
      status: "draft"
    )
    claim.save!
    claim.reload
  end

  def authorize_referral!(referral)
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
    referral.authorize! if referral.may_authorize? && !referral.committee_review?
    referral.reload
  end

  def referral_at
    kase = Corvid::Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "REF-SENT-MARK-#{SecureRandom.hex(3)}",
      facility_identifier: FACILITY
    )
  end
end
