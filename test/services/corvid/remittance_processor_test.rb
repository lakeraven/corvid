# frozen_string_literal: true

require "test_helper"

class Corvid::RemittanceProcessorTest < ActiveSupport::TestCase
  TENANT = "tnt_remit_test"

  test "a denied line item marks the claim denied with normalized CARC codes" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-1")

      result = Corvid::RemittanceProcessor.call([
        remittance(claim_identifier: "CLM-R-1", paid_amount: 0, status: "denied",
                   denial_reason: "MOCK NOTE 001",
                   adjustment_codes: [ "CO-97:$50.00", { group_code: "PR", reason_code: "204" } ])
      ])

      claim.reload
      assert claim.denied?
      assert_equal %w[CO-97 PR-204], claim.denial_reason_codes
      assert_not_nil claim.denied_at
      assert_nil claim.rejected_at
      assert_equal 1, result.denied
    end
  end

  test "a paid line item marks the claim paid with its amounts" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-2")

      result = Corvid::RemittanceProcessor.call([
        remittance(claim_identifier: "CLM-R-2", paid_amount: 300.0, adjustment_amount: 50.0)
      ])

      claim.reload
      assert claim.paid?
      assert_equal Money.from_amount(300, "USD"), claim.paid_amount
      assert_equal Money.from_amount(50, "USD"), claim.adjustment_amount
      assert_equal Date.new(2026, 10, 1), claim.paid_date
      assert_equal 1, result.paid
    end
  end

  test "a line item with no payment and no denial only updates amounts" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-3")

      Corvid::RemittanceProcessor.call([
        remittance(claim_identifier: "CLM-R-3", paid_amount: 0, patient_responsibility: 25.0)
      ])

      claim.reload
      assert_equal "accepted", claim.status
      assert_equal Money.from_amount(25, "USD"), claim.patient_responsibility
    end
  end

  test "line items for claims outside the tenant are not matched" do
    with_tenant("tnt_other") { create_claim("CLM-R-4") }

    with_tenant(TENANT) do
      result = Corvid::RemittanceProcessor.call([
        remittance(claim_identifier: "CLM-R-4", paid_amount: 0, status: "denied")
      ])

      assert_equal 1, result.unmatched
      assert_equal 0, result.denied
    end

    with_tenant("tnt_other") do
      assert_equal "accepted", Corvid::ClaimSubmission.find_by(claim_identifier: "CLM-R-4").status
    end
  end

  test "a line item with no claim identifier matches no claim" do
    with_tenant(TENANT) do
      draft = Corvid::ClaimSubmission.create!(
        patient_identifier: "pt_remit", claim_type: "professional", status: "draft", billed_amount: 400.0
      )

      result = Corvid::RemittanceProcessor.call([
        remittance(claim_identifier: nil, paid_amount: 300.0)
      ])

      assert_equal 1, result.unmatched
      assert_equal 0, result.paid
      assert_equal "draft", draft.reload.status
      assert_nil draft.paid_amount
    end
  end

  test "amounts from several remittances for one claim are summed, not overwritten by the last line" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-SUM-1")

      Corvid::RemittanceProcessor.call([
        remittance(remittance_identifier: "REM-SUM-A", claim_identifier: "CLM-R-SUM-1",
                   paid_amount: 100.05, adjustment_amount: 10.0),
        remittance(remittance_identifier: "REM-SUM-B", claim_identifier: "CLM-R-SUM-1",
                   paid_amount: 0.10, adjustment_amount: 5.0)
      ])

      claim.reload
      assert_equal 10_015, claim.paid_amount_cents,
        "$100.05 + $0.10 must be $100.15 in cents; binary floats read a cent short when summed as floats"
      assert_equal 1500, claim.adjustment_amount_cents
    end
  end

  test "the same remittance_identifier twice in one call counts the payment once" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-DUP-ID")

      dup = remittance(remittance_identifier: "REM-DUP-1", claim_identifier: "CLM-R-DUP-ID",
                       paid_amount: 300.0)
      Corvid::RemittanceProcessor.call([
        dup, dup.deep_dup,
        remittance(remittance_identifier: "REM-DUP-2", payment_date: Date.new(2026, 10, 2),
                   claim_identifier: "CLM-R-DUP-ID", paid_amount: 50.0)
      ])

      claim.reload
      assert_equal 35_000, claim.paid_amount_cents
    end
  end

  test "an unidentified remittance repeated with identical content counts once" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-DUP-NOID")

      dup = remittance(remittance_identifier: "REM-IGNORED", claim_identifier: "CLM-R-DUP-NOID",
                       paid_amount: 300.0).except(:remittance_identifier)
      later = remittance(remittance_identifier: "REM-IGNORED-2", payment_date: Date.new(2026, 10, 2),
                         claim_identifier: "CLM-R-DUP-NOID", paid_amount: 50.0).except(:remittance_identifier)
      Corvid::RemittanceProcessor.call([ dup, dup.deep_dup, later ])

      claim.reload
      assert_equal 35_000, claim.paid_amount_cents
    end
  end

  test "reversal remittances net against earlier payments for the claim" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-REV")

      Corvid::RemittanceProcessor.call([
        remittance(remittance_identifier: "REM-CORR", payment_date: Date.new(2026, 10, 3),
                   claim_identifier: "CLM-R-REV", paid_amount: 200.0),
        remittance(remittance_identifier: "REM-PAY", payment_date: Date.new(2026, 10, 1),
                   claim_identifier: "CLM-R-REV", paid_amount: 250.0),
        remittance(remittance_identifier: "REM-REV", payment_date: Date.new(2026, 10, 2),
                   claim_identifier: "CLM-R-REV", paid_amount: -250.0)
      ])

      claim.reload
      assert_equal 20_000, claim.paid_amount_cents
    end
  end

  test "denied_amount on a line is stored with contractual adjustments" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-DENY-ADJ")

      Corvid::RemittanceProcessor.call([
        remittance(claim_identifier: "CLM-R-DENY-ADJ", paid_amount: 0,
                   adjustment_amount: 30.0, denied_amount: 20.0)
      ])

      claim.reload
      assert_equal 5000, claim.adjustment_amount_cents
    end
  end

  test "amount fields not stated on any remittance line are left unchanged" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-UNSTATED")
      claim.update!(patient_responsibility: 15.0)

      Corvid::RemittanceProcessor.call([
        remittance(claim_identifier: "CLM-R-UNSTATED", paid_amount: 50.0)
      ])

      claim.reload
      assert_equal Money.from_amount(15, "USD"), claim.patient_responsibility
    end
  end

  test "processor and referral billing reconciliation apply the same amount rules" do
    with_tenant(TENANT) do
      referral = referral_for("R-SUM-EQ")
      claim = accepted_claim_for_referral("CLM-R-SUM-EQ", referral, billed: 500.0)

      remittances = [
        remittance(remittance_identifier: "REM-EQ-1", claim_identifier: claim.claim_identifier,
                   paid_amount: 100.05, adjustment_amount: 10.0),
        remittance(remittance_identifier: "REM-EQ-2", claim_identifier: claim.claim_identifier,
                   paid_amount: 0.10, adjustment_amount: 5.0, patient_responsibility: 25.0)
      ]

      Corvid::RemittanceProcessor.call(remittances)
      processor_amounts = amount_snapshot(claim.reload)

      claim.update!(
        paid_amount_cents: nil, adjustment_amount_cents: nil,
        patient_responsibility_cents: nil, paid_date: nil, status: "accepted"
      )

      reconcile_against(claim, remittances)
      reconcile_amounts = amount_snapshot(claim.reload)

      assert_equal reconcile_amounts, processor_amounts
    end
  end

  test "paid_date is the latest payment_date among remittances for the claim, not the last line processed" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-PDATE")

      Corvid::RemittanceProcessor.call([
        remittance(remittance_identifier: "REM-PDATE-LATE", payment_date: Date.new(2026, 10, 3),
                   claim_identifier: "CLM-R-PDATE", paid_amount: 10.0),
        remittance(remittance_identifier: "REM-PDATE-EARLY", payment_date: Date.new(2026, 10, 1),
                   claim_identifier: "CLM-R-PDATE", paid_amount: 20.0)
      ])

      claim.reload
      assert_equal Date.new(2026, 10, 3), claim.paid_date
    end
  end

  private

  def create_claim(claim_identifier)
    Corvid::ClaimSubmission.create!(
      patient_identifier: "pt_remit",
      claim_type: "professional",
      claim_identifier: claim_identifier,
      service_date: Date.current,
      status: "accepted",
      submitted_at: 2.days.ago,
      billed_amount: 400.0
    )
  end

  def remittance(remittance_identifier: nil, payment_date: Date.new(2026, 10, 1), **line_item)
    {
      remittance_identifier: remittance_identifier || "REM-#{line_item[:claim_identifier]}",
      payer_name: "Test Payer",
      payment_date: payment_date,
      total_paid: line_item[:paid_amount],
      line_items: [ line_item ]
    }
  end

  def referral_for(identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_#{identifier}", facility_identifier: "fac_remit"
    )
    Corvid::PrcReferral.create!(
      case: kase, referral_identifier: identifier, facility_identifier: "fac_remit"
    )
  end

  def accepted_claim_for_referral(claim_identifier, referral, billed:)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT, facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier, prc_referral: referral,
      referral_identifier: referral.referral_identifier, claim_type: "professional",
      service_date: Date.current, billed_amount: billed, status: "accepted",
      claim_identifier: claim_identifier, submitted_at: 2.days.ago
    )
  end

  def reconcile_against(claim, remittances)
    Corvid.adapter.stub(:fetch_remittances, remittances) do
      Corvid::ReferralBillingReconciliation.reconcile!(
        referral: claim.prc_referral, claim: claim
      )
    end
  end

  def amount_snapshot(claim)
    {
      paid_amount_cents: claim.paid_amount_cents,
      adjustment_amount_cents: claim.adjustment_amount_cents,
      patient_responsibility_cents: claim.patient_responsibility_cents
    }
  end
end
