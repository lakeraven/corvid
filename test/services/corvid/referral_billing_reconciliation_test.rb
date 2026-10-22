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

  test "a partial denial that accounts for the rest of the bill settles it" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-PARTDENY", billed: 500.0)

      reconcile_with(claim, paid: 350.0, adjustment: 100.0, denied: 50.0)

      assert_equal "paid", claim.reload.status
      assert_equal 0, claim.balance_due.cents,
        "the denied $50 is accounted for, so nothing is still owed on the claim"
    end
  end

  test "a bill covered entirely by patient responsibility is settled without a payer payment" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-ALLPR", billed: 100.0)

      reconcile_with(claim, paid: 0.0, patient_responsibility: 100.0)

      assert_equal "paid", claim.reload.status
    end
  end

  test "a bill accounted for only by denied amounts is a denial, not a payment" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-ALLDENY", billed: 425.0)

      reconcile_with(claim, paid: 0.0, denied: 425.0)

      assert_equal "denied", claim.reload.status
    end
  end

  test "cent amounts that add up to the bill settle it exactly" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-CENTS", billed: 100.15)

      reconcile_with(claim, paid: 100.05, adjustment: 0.10)

      assert_equal "paid", claim.reload.status,
        "$100.05 + $0.10 is $100.15; binary floats read it as a cent short"
    end
  end

  test "payments across several remittances together settle the claim" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-SPLIT", billed: 500.0)

      remittances = [
        remittance("REM-SPLIT-1", claim, paid: 250.0),
        remittance("REM-SPLIT-2", claim, paid: 250.0)
      ]
      reconcile_against(claim, remittances)
      reconcile_against(claim, remittances)

      assert_equal "paid", claim.reload.status
      assert_equal 500.0, claim.paid_amount.to_f,
        "reading the same remittances again must not count them twice"
    end
  end

  test "the same remittance returned twice is counted once" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-DUP", billed: 500.0)

      rem = remittance("REM-DUP", claim, paid: 250.0)
      reconcile_against(claim, [ rem, rem ])

      refute_equal "paid", claim.reload.status
      assert_equal 250.0, claim.paid_amount.to_f
    end
  end

  test "a reversal and corrected remittance replace the original payment" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-CORRECT", billed: 425.0)

      reconcile_against(claim, [
        remittance("REM-ORIG", claim, paid: 100.0),
        remittance("REM-REVERSAL", claim, paid: -100.0),
        remittance("REM-CORRECTED", claim, paid: 425.0)
      ])

      assert_equal "paid", claim.reload.status
      assert_equal 425.0, claim.paid_amount.to_f
    end
  end

  test "a payment after a denial settles the claim" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-APPEAL", billed: 300.0)

      reconcile_against(claim, [
        remittance("REM-DENY", claim, paid: 0.0, line_status: "denied", date: 10.days.ago.to_date),
        remittance("REM-APPEAL", claim, paid: 300.0, date: Date.current)
      ])

      assert_equal "paid", claim.reload.status
    end
  end

  test "remittances that cannot be read leave the claim untouched" do
    with_tenant(TENANT) do
      claim = accepted_claim("RC-UNKNOWN", billed: 100.0)

      result = reconcile_against(claim, nil)

      assert_equal "accepted", claim.reload.status
      assert_equal "pending", result.status
    end
  end

  # --- what "reconciled" means ---------------------------------------------

  test "a claim already marked paid short of the bill does not reconcile" do
    with_tenant(TENANT) do
      referral = referral_for("RC-STALEPAID")
      claim = accepted_claim("RC-STALEPAID", billed: 425.0, referral: referral)
      claim.mark_paid!(paid_amount: 100.0)
      deliver!(referral)

      result = reconcile_against(claim, [])

      assert_equal "pending", result.status,
        "a stored paid status is not proof the bill was accounted for"
    end
  end

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
    denied: nil, line_status: nil, referral: nil)
    rem = remittance("REM-#{claim.claim_identifier}", claim, paid: paid, adjustment: adjustment,
      patient_responsibility: patient_responsibility, denied: denied, line_status: line_status)
    reconcile_against(claim, [ rem ], referral: referral)
  end

  def remittance(identifier, claim, paid:, adjustment: nil, patient_responsibility: nil,
    denied: nil, line_status: nil, date: Date.current)
    line = { claim_identifier: claim.claim_identifier, paid_amount: paid }
    line[:adjustment_amount] = adjustment if adjustment
    line[:patient_responsibility] = patient_responsibility if patient_responsibility
    line[:denied_amount] = denied if denied
    line[:status] = line_status if line_status

    { remittance_identifier: identifier, payment_date: date, line_items: [ line ] }
  end

  def reconcile_against(claim, remittances, referral: nil)
    Corvid.adapter.stub(:fetch_remittances, remittances) do
      Corvid::ReferralBillingReconciliation.reconcile!(
        referral: referral || claim.prc_referral, claim: claim
      )
    end
  end
end
