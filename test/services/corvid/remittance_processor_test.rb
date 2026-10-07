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

  def remittance(**line_item)
    {
      remittance_identifier: "REM-#{line_item[:claim_identifier]}",
      payer_name: "Test Payer",
      payment_date: Date.new(2026, 10, 1),
      total_paid: line_item[:paid_amount],
      line_items: [ line_item ]
    }
  end
end
