# frozen_string_literal: true

require "test_helper"

# Review finding (PR #598, high): "Enforce referral fulfilment in
# ClaimSubmission#submit!" — adding the belongs_to :prc_referral
# association did not, by itself, stop a caller from invoking
# ClaimSubmission#submit! directly on a referral-linked claim whose
# referral has not recorded delivered care. Corvid::MedicaidReferralBilling
# enforces the gate in its own path, but that is a courtesy, not a
# structural guarantee — this pins the guarantee to the model itself.
class Corvid::ClaimSubmissionFulfilmentGateTest < ActiveSupport::TestCase
  TENANT = "tnt_cs_fulfilment_gate"

  test "submit! rejects a referral-linked claim when fulfilment has not recorded delivered care" do
    with_tenant(TENANT) do
      referral = create_referral("rf_gate_1")
      claim = create_claim(referral)

      refute Corvid::ReferralFulfilment.billable_for_delivered_care?(referral),
        "Precondition: no fulfilment report has been recorded for this referral"

      assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) { claim.submit! }
      assert_equal "draft", claim.reload.status,
        "A rejected submission must not advance claim status"
    end
  end

  test "submit! proceeds once fulfilment has recorded delivered care" do
    with_tenant(TENANT) do
      referral = create_referral("rf_gate_2")
      claim = create_claim(referral)

      Corvid::ReferralFulfilment.record_external_report!(
        referral, source: "receiving_specialist", outcome: "delivered",
        reported_at: Time.current
      )

      result = claim.submit!
      assert_equal "submitted", claim.reload.status
      assert_equal "accepted", result[:status]
    end
  end

  test "submit! is unaffected for claims with no referral association" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        patient_identifier: "pt_no_ref", claim_type: "professional",
        service_date: Date.current, billed_amount: 100.0, status: "draft"
      )

      result = claim.submit!
      assert_equal "submitted", claim.reload.status
      assert_equal "accepted", result[:status]
    end
  end

  private

  # Authorized, because these tests isolate the FULFILMENT gate. Leaving the
  # referral in `draft` made the "proceeds once fulfilment is recorded" case
  # assert that an unauthorized referral could be billed — pinning a bypass as
  # correct rather than testing the gate under test. Authorization is covered
  # separately in referral_billing_review_blockers_test.rb.
  def create_referral(referral_id)
    kase = Corvid::Case.create!(patient_identifier: "pt_gate_#{referral_id}", facility_identifier: "fac_gate")
    referral = Corvid::PrcReferral.create!(case: kase, referral_identifier: referral_id, facility_identifier: "fac_gate")
    Corvid::MedicaidReferralWorkflow.bootstrap_authorized_medicaid_referral!(referral)
    referral.reload
  end

  def create_claim(referral)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT, facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier, prc_referral: referral,
      referral_identifier: referral.referral_identifier, claim_type: "professional",
      service_date: Date.current, billed_amount: 100.0, status: "draft"
    )
  end
end
