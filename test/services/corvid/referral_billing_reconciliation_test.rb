# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Reconciling a referral's claim asks two questions that have to be answered
# together: did the payer settle the bill, and is there a record that the care
# was actually delivered. Payment alone proves nothing about delivery, and a
# delivery report proves nothing about money, so "reconciled" requires both.
class Corvid::ReferralBillingReconciliationTest < ActiveSupport::TestCase
  TENANT = "tnt_reconcile"

  # --- settlement ----------------------------------------------------------
  #
  # An 835 accounts for a billed amount across payment, contractual
  # adjustments, patient responsibility and denied lines. The claim is settled
  # when those together cover what was billed — not whenever any money arrives.
  # features/billing/remittance.feature's partial-denial scenario states the
  # same identity: $350 paid + $100 adjustment + $50 denied against $500.

  test "a payment that accounts for the billed amount settles the claim" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-FULL", billed: 500.0)

      reconcile_with(claim, paid: 350.0, adjustment: 100.0, patient_responsibility: 50.0)

      assert_equal "paid", claim.reload.status
    end
  end

  test "a short payment leaves the claim outstanding" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-PARTIAL", billed: 425.0)

      reconcile_with(claim, paid: 100.0)

      refute_equal "paid", claim.reload.status,
        "$100 against $425 leaves $325 owed; calling it paid writes the balance off"
      assert_equal 100.0, claim.paid_amount.to_f, "the payment is still recorded"
    end
  end

  test "a denied line marks the claim denied rather than leaving it pending" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-DENIED", billed: 425.0)

      reconcile_with(claim, paid: 0.0, line_status: "denied")

      assert_equal "denied", claim.reload.status,
        "a denial is an answer; the claim must not sit accepted forever"
    end
  end

  test "a zero payment with no denial leaves the claim as it was" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-ZERO", billed: 425.0)

      reconcile_with(claim, paid: 0.0)

      assert_equal "accepted", claim.reload.status,
        "no money and no denial is not an outcome to record"
    end
  end

  # --- what "reconciled" means ---------------------------------------------

  test "a settled claim with delivered care reconciles" do
    with_tenant(TENANT) do
      referral = referral_for("RC-OK")
      claim = accepted_claim("RC-OK", billed: 100.0, referral: referral)
      deliver!(referral)

      result = reconcile_with(claim, paid: 100.0, referral: referral)

      assert_equal "reconciled", result.status
      assert result.fulfilment_verified
    end
  end

  test "a settled claim without a delivery record does not reconcile" do
    with_tenant(TENANT) do
      referral = referral_for("RC-NODELIVERY")
      claim = accepted_claim("RC-NODELIVERY", billed: 100.0, referral: referral)

      result = reconcile_with(claim, paid: 100.0, referral: referral)

      assert_equal "paid", claim.reload.status
      assert_equal "pending", result.status,
        "payment is not evidence that the care happened"
      refute result.fulfilment_verified
    end
  end

  test "delivered care on an unsettled claim does not reconcile" do
    with_tenant(TENANT) do
      referral = referral_for("RC-UNPAID")
      claim = accepted_claim("RC-UNPAID", billed: 400.0, referral: referral)
      deliver!(referral)

      result = reconcile_with(claim, paid: 50.0, referral: referral)

      assert_equal "pending", result.status
      assert result.fulfilment_verified
    end
  end

  # --- the two arguments must describe the same thing ----------------------

  test "reconciling a claim against a referral it does not bill is refused" do
    with_tenant(TENANT) do
      billed = referral_for("RC-MINE")
      other = referral_for("RC-OTHER")
      claim = accepted_claim("RC-MINE", billed: 100.0, referral: billed)

      assert_raises(Corvid::ReferralBillingReconciliation::AssociationMismatch) do
        Corvid::ReferralBillingReconciliation.reconcile!(referral: other, claim: claim)
      end
    end
  end

  test "reconciling an unlinked claim is refused" do
    with_tenant(TENANT) do
      referral = referral_for("RC-UNLINKED")
      claim = accepted_claim("RC-UNLINKED", billed: 100.0, referral: referral)
      claim.update_column(:prc_referral_id, nil)

      assert_raises(Corvid::ReferralBillingReconciliation::AssociationMismatch) do
        Corvid::ReferralBillingReconciliation.reconcile!(referral: referral, claim: claim.reload)
      end
    end
  end

  private

  def referral_for(identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_#{identifier}", facility_identifier: "fac_rc"
    )
    Corvid::PrcReferral.create!(
      case: kase, referral_identifier: identifier, facility_identifier: "fac_rc"
    )
  end

  def accepted_claim(identifier, billed:, referral: nil)
    referral ||= referral_for(identifier)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT, facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier, prc_referral: referral,
      referral_identifier: referral.referral_identifier, claim_type: "professional",
      service_date: Date.current, billed_amount: billed, status: "accepted",
      claim_identifier: "CLM-#{identifier}"
    )
  end

  def deliver!(referral)
    Corvid::ReferralFulfilment.record_external_report!(
      referral, source: "receiving_specialist", outcome: "delivered", reported_at: Time.current
    )
  end

  def reconcile_with(claim, paid:, adjustment: nil, patient_responsibility: nil,
    line_status: nil, referral: nil)
    line = { claim_identifier: claim.claim_identifier, paid_amount: paid }
    line[:adjustment_amount] = adjustment if adjustment
    line[:patient_responsibility] = patient_responsibility if patient_responsibility
    line[:status] = line_status if line_status

    Corvid.adapter.stub(:fetch_remittances,
      [ { payment_date: Date.current, line_items: [ line ] } ]) do
      Corvid::ReferralBillingReconciliation.reconcile!(
        referral: referral || claim.prc_referral, claim: claim
      )
    end
  end
end
