# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 F1: resolving a referral link on every save must not
# block lifecycle moves on ordinary (unlinked) sent claims when a matching
# PrcReferral appears later. F5a/F5c: stored-link and per-marker attach guards.
class Corvid::ClaimSubmissionUnlinkedSentClaimTest < ActiveSupport::TestCase
  TENANT = "tnt_unlinked_sent_668"
  FACILITY = "fac_unlinked_sent_668"
  PATIENT = "pt_unlinked_sent_668"
  SENT_MARKER_MESSAGE = Corvid::ClaimSubmission::SENT_MARKER_MESSAGE
  CLAIM_ID = "CLM-UNLINKED-SENT-668"

  teardown { Corvid.reset_configuration! }

  test "check_status! on sent unlinked claim after referral appears stays unlinked" do
    with_tenant(TENANT) do
      claim = sent_unlinked_claim!("REF-LATER-CHK")
      referral_for!("REF-LATER-CHK")
      Corvid.adapter.define_singleton_method(:check_claim_status) { |_| { status: "accepted" } }

      assert_nothing_raised { claim.check_status! }

      claim.reload
      assert_equal "accepted", claim.status
      assert_nil claim.prc_referral_id,
        "ordinary billing must not auto-link when status is polled after referral is entered"
    end
  end

  test "mark_paid! on sent unlinked claim after referral appears stays unlinked" do
    with_tenant(TENANT) do
      claim = sent_unlinked_claim!("REF-LATER-PAID")
      referral_for!("REF-LATER-PAID")

      assert_nothing_raised { claim.mark_paid!(paid_amount: 10) }

      claim.reload
      assert_equal "paid", claim.status
      assert_nil claim.prc_referral_id
    end
  end

  test "RemittanceProcessor on sent unlinked claim after referral appears stays unlinked" do
    with_tenant(TENANT) do
      claim = sent_unlinked_claim!("REF-LATER-REM")
      referral_for!("REF-LATER-REM")

      result = Corvid::RemittanceProcessor.call([
        { payment_date: Date.current, line_items: [ { claim_identifier: CLAIM_ID, paid_amount: 50 } ] }
      ])

      claim.reload
      assert_equal "paid", claim.status
      assert_equal 1, result.paid
      assert_nil claim.prc_referral_id
    end
  end

  test "plain edit on unlinked error claim with submitted_at does not auto-link when referral exists" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: FACILITY,
        patient_identifier: PATIENT,
        referral_identifier: "REF-ERR-PLAIN",
        claim_type: "professional",
        service_date: Date.new(2025, 6, 10),
        billed_amount: 100.0,
        status: "draft"
      )
      claim.update_columns(status: "error", submitted_at: Time.zone.parse("2025-06-15 09:00:00 UTC"))
      claim.reload
      assert_nil claim.prc_referral_id

      referral_for!("REF-ERR-PLAIN")

      assert_nothing_raised { claim.update!(billed_amount: 101.0) }

      claim.reload
      assert_equal 101.0, claim.billed_amount.to_f
      assert_nil claim.prc_referral_id
    end
  end

  test "explicit referral_identifier relink of sent unlinked claim is still refused" do
    with_tenant(TENANT) do
      referral = referral_for!("REF-EXPLICIT-RELINK")
      claim = sent_unlinked_claim!("REF-ORPHAN-EXPLICIT")

      error = assert_raises(ActiveRecord::RecordInvalid) do
        claim.update!(referral_identifier: referral.referral_identifier)
      end

      assert error.record.errors[:claim_identifier].include?(SENT_MARKER_MESSAGE) ||
        error.record.errors[:submitted_at].include?(SENT_MARKER_MESSAGE) ||
        error.record.errors[:status].present?
      assert_nil claim.reload.prc_referral_id
    end
  end

  test "explicit prc_referral= on sent unlinked claim is still refused" do
    with_tenant(TENANT) do
      referral = referral_for!("REF-EXPLICIT-ASSOC")
      claim = sent_unlinked_claim!("REF-ORPHAN-ASSOC")
      claim.update_columns(referral_identifier: nil)
      claim.reload

      claim.prc_referral = referral
      refute claim.save
      assert_nil claim.reload.prc_referral_id
    end
  end

  test "stored link guard refuses one save that unlinks and marks sent with DB unchanged" do
    with_tenant(TENANT) do
      referral = referral_for!("REF-STORED-LINK")
      claim = linked_draft_claim!(referral)
      before = claim.attributes.slice("referral_identifier", "status", "claim_identifier", "prc_referral_id")

      refute claim.update(
        referral_identifier: "DECOY-UNMATCHED-668",
        status: "accepted",
        claim_identifier: "CLM-STORED-LINK"
      )

      claim.reload
      referral.reload
      after = claim.attributes.slice("referral_identifier", "status", "claim_identifier", "prc_referral_id")
      assert_equal before, after
      assert_equal referral.id, claim.prc_referral_id
      assert referral.draft?
    end
  end

  test "cannot_attach_ungated_sent_claim refuses link when only claim_identifier is set" do
    with_tenant(TENANT) do
      referral = referral_for!("REF-MARKER-ID")
      claim = unlinked_claim_shell!("REF-ORPHAN-ID")
      claim.update_columns(claim_identifier: "CLM-MARKER-ONLY-ID")
      claim.reload

      assert_attach_refused!(claim, referral)
    end
  end

  test "cannot_attach_ungated_sent_claim refuses link when only submitted_at is set" do
    with_tenant(TENANT) do
      referral = referral_for!("REF-MARKER-STAMP")
      claim = unlinked_claim_shell!("REF-ORPHAN-STAMP")
      claim.update_columns(submitted_at: Time.zone.parse("2025-06-15 10:00:00 UTC"))
      claim.reload

      assert_attach_refused!(claim, referral)
    end
  end

  test "cannot_attach_ungated_sent_claim refuses link when only a sent status is set" do
    with_tenant(TENANT) do
      referral = referral_for!("REF-MARKER-STATUS")
      claim = unlinked_claim_shell!("REF-ORPHAN-STATUS")
      claim.update_columns(status: "submitted")
      claim.reload

      assert_attach_refused!(claim, referral)
    end
  end

  private

  def assert_attach_refused!(claim, referral)
    assert_nil claim.prc_referral_id

    error = assert_raises(ActiveRecord::RecordInvalid) do
      claim.update!(
        referral_identifier: referral.referral_identifier,
        patient_identifier: referral.case.patient_identifier
      )
    end

    assert error.record.errors[:claim_identifier].include?(SENT_MARKER_MESSAGE) ||
      error.record.errors[:submitted_at].include?(SENT_MARKER_MESSAGE) ||
      error.record.errors[:status].present?
    assert_nil claim.reload.prc_referral_id
  end

  def referral_for!(identifier)
    kase = Corvid::Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: FACILITY
    )
  end

  def sent_unlinked_claim!(referral_identifier)
    claim = Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: FACILITY,
      patient_identifier: PATIENT,
      referral_identifier: referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 10),
      billed_amount: 100.0,
      status: "draft"
    )
    Corvid.adapter.define_singleton_method(:submit_claim) do |_|
      { claim_identifier: CLAIM_ID, status: "accepted" }
    end
    record_system_of_record(facility_identifier: FACILITY, tenant_identifier: TENANT)
    claim.submit!
    claim.reload
    assert_nil claim.prc_referral_id
    assert_equal "submitted", claim.status
    claim
  end

  def unlinked_claim_shell!(referral_identifier)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: FACILITY,
      patient_identifier: PATIENT,
      referral_identifier: referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 10),
      billed_amount: 100.0,
      status: "draft"
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
