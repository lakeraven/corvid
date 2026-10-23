# frozen_string_literal: true

require "test_helper"

# Claim submission for a linked PRC referral requires an external fulfilment
# report naming delivered care (#675). These tests pin the gate on both adapter
# submission and manual mark_submitted! paths.
class Corvid::ClaimSubmissionFulfilmentGateTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  FACILITY = "fac_test"
  PATIENT = "TEST,PATIENT 001"

  test "submit! refuses a linked authorized referral with no fulfilment report" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_gate_none")
      claim = linked_claim(referral)

      error = assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) { claim.submit! }

      assert_match(/fulfilment|delivered|awaiting_report/i, error.message)
      assert_equal "draft", claim.reload.status
      assert_nil claim.submitted_at
    end
  end

  test "submit! refuses when the latest fulfilment report is not_delivered" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_gate_not_delivered")
      record_external_report!(referral, outcome: "not_delivered", reported_at: Time.current)
      claim = linked_claim(referral)

      assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) { claim.submit! }
      assert_equal "draft", claim.reload.status
    end
  end

  test "submit! refuses when a later not_delivered report supersedes delivered" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_gate_superseded")
      record_external_report!(referral, outcome: "delivered", reported_at: 2.days.ago)
      record_external_report!(referral, outcome: "not_delivered", reported_at: Time.current)
      claim = linked_claim(referral)

      assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) { claim.submit! }
    end
  end

  test "submit! proceeds for a linked referral whose latest report is delivered" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_gate_ok")
      record_external_report!(referral, outcome: "delivered", reported_at: Time.current)
      claim = linked_claim(referral)

      claim.submit!

      assert_equal "submitted", claim.reload.status
      refute_nil claim.submitted_at
    end
  end

  test "mark_submitted! refuses without a delivered fulfilment report" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_mark_none")
      claim = linked_claim(referral)

      assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) do
        claim.mark_submitted!(claim_identifier: "CLM-MANUAL-1")
      end
      assert_equal "draft", claim.reload.status
      assert_nil claim.claim_identifier
    end
  end

  test "mark_submitted! proceeds when delivered care is recorded" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_mark_ok")
      record_external_report!(referral, outcome: "delivered", reported_at: Time.current)
      claim = linked_claim(referral)

      claim.mark_submitted!(claim_identifier: "CLM-MANUAL-2")

      assert_equal "submitted", claim.reload.status
      assert_equal "CLM-MANUAL-2", claim.claim_identifier
    end
  end

  test "submit! without a linked referral is unchanged by the fulfilment gate" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: FACILITY,
        patient_identifier: PATIENT,
        referral_identifier: "EXTERNAL-ONLY-675",
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 100.0,
        status: "draft"
      )
      assert_nil claim.prc_referral_id

      claim.submit!

      assert_equal "submitted", claim.reload.status
    end
  end

  private

  def authorized_referral(identifier)
    kase = Corvid::Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
    referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: FACILITY
    )
    Corvid::AlternateResourceCheck.create_all_for_referral(referral)
    exhaust_alternate_resources!(referral)
    referral.update_column(:status, "authorized")
    referral.reload
  end

  def linked_claim(referral)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier,
      prc_referral: referral,
      referral_identifier: referral.referral_identifier,
      claim_type: "professional",
      service_date: Date.current,
      billed_amount: 100.0,
      status: "draft"
    )
  end

  def record_external_report!(referral, outcome:, reported_at:)
    Corvid::ReferralFulfilment.record_external_report!(
      referral,
      source: "receiving_specialist",
      outcome: outcome,
      reported_at: reported_at
    )
  end
end
