# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 finding 2: unlinking via referral_identifier must not bypass
# submission and sent-marker guards; relinking must not leave a sent claim on a
# draft referral.
class Corvid::ClaimSubmissionRelinkGuardTest < ActiveSupport::TestCase
  TENANT = "tnt_relink_668"
  FACILITY = "fac_relink_668"
  PATIENT = "pt_test_668"
  SENT_MARKER_MESSAGE = Corvid::ClaimSubmission::SENT_MARKER_MESSAGE

  test "unlink then relink cannot attach sent markers to a draft referral" do
    with_tenant(TENANT) do
      referral = draft_referral!("rf_test_668")
      claim = linked_draft_claim!(referral)
      decoy_identifier = "rf_unlink_decoy_668"

      rejected = assert_relink_bypass_rejected(claim, referral, decoy_identifier)

      assert rejected, "expected unlink-then-relink bypass to raise RecordInvalid on a save"
      refute_linked_sent_markers_on_draft_referral!(claim, referral)
    end
  end

  test "linking an unlinked claim that already carries sent markers is rejected" do
    with_tenant(TENANT) do
      referral = draft_referral!("rf_test_668")
      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: FACILITY,
        patient_identifier: PATIENT,
        referral_identifier: "rf_orphan_668",
        claim_type: "professional",
        service_date: Date.new(2025, 6, 10),
        billed_amount: 100.0,
        status: "draft"
      )
      assert_nil claim.prc_referral_id, "precondition: claim is not linked to a PRC referral"

      claim.update_columns(
        status: "submitted",
        claim_identifier: "CLM-ORPHAN-668",
        submitted_at: Time.zone.parse("2025-06-15 10:00:00 UTC")
      )
      claim.reload

      error = assert_raises(ActiveRecord::RecordInvalid) do
        claim.update!(
          referral_identifier: referral.referral_identifier,
          patient_identifier: referral.case.patient_identifier
        )
      end

      assert error.record.errors[:claim_identifier].include?(SENT_MARKER_MESSAGE) ||
        error.record.errors[:submitted_at].include?(SENT_MARKER_MESSAGE) ||
        error.record.errors[:status].present?,
        "expected sent-marker or submission gate errors, got #{error.record.errors.full_messages}"
      refute_linked_sent_markers_on_draft_referral!(claim, referral)
    end
  end

  private

  def assert_relink_bypass_rejected(claim, referral, decoy_identifier)
    rejected = false

    begin
      claim.update!(
        referral_identifier: decoy_identifier,
        status: "submitted",
        claim_identifier: "CLM-RELINK-668",
        submitted_at: Time.zone.parse("2025-06-15 11:00:00 UTC")
      )
    rescue ActiveRecord::RecordInvalid
      rejected = true
    end

    unless rejected
      begin
        claim.update!(referral_identifier: referral.referral_identifier)
      rescue ActiveRecord::RecordInvalid
        rejected = true
      end
    end

    rejected
  end

  def refute_linked_sent_markers_on_draft_referral!(claim, referral)
    claim.reload
    referral.reload
    linked_to_draft = claim.prc_referral_id == referral.id && referral.status == "draft"
    carries_sent_markers = claim.claim_identifier.present? ||
      claim.submitted_at.present? ||
      Corvid::ClaimSubmission::SENT_STATUSES.include?(claim.status)

    refute linked_to_draft && carries_sent_markers,
      "must not persist a linked claim with sent markers against draft referral #{referral.referral_identifier}, " \
      "claim status=#{claim.status} claim_identifier=#{claim.claim_identifier.inspect}"
  end

  def draft_referral!(identifier)
    kase = Corvid::Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: FACILITY
    )
  end

  def linked_draft_claim!(referral)
    claim = Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: FACILITY,
      patient_identifier: referral.case.patient_identifier,
      referral_identifier: referral.referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 10),
      billed_amount: 100.0,
      status: "draft"
    )
    assert_equal referral.id, claim.reload.prc_referral_id
    claim
  end
end
