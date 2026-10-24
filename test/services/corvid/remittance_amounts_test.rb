# frozen_string_literal: true

require "test_helper"

class Corvid::RemittanceAmountsTest < ActiveSupport::TestCase
  TENANT = "tnt_remit_amt_test"

  test "parses numeric and formatted currency strings into integer cents" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-AMT-FMT")

      result = Corvid::RemittanceAmounts.call(claim: claim, remittances: [
        remittance(claim_identifier: "CLM-AMT-FMT", paid_amount: "12.50"),
        remittance(remittance_identifier: "REM-COMMA", payment_date: Date.new(2026, 10, 2),
                   claim_identifier: "CLM-AMT-FMT", paid_amount: "1,234.56"),
        remittance(remittance_identifier: "REM-DOLLAR", payment_date: Date.new(2026, 10, 3),
                   claim_identifier: "CLM-AMT-FMT", paid_amount: "$50.00"),
        remittance(remittance_identifier: "REM-INT", payment_date: Date.new(2026, 10, 4),
                   claim_identifier: "CLM-AMT-FMT", paid_amount: 7),
        remittance(remittance_identifier: "REM-FLOAT", payment_date: Date.new(2026, 10, 5),
                   claim_identifier: "CLM-AMT-FMT", paid_amount: 0.25),
        remittance(remittance_identifier: "REM-BD", payment_date: Date.new(2026, 10, 6),
                   claim_identifier: "CLM-AMT-FMT", paid_amount: BigDecimal("0.10"))
      ])

      assert_equal 1_250 + 123_456 + 5_000 + 700 + 25 + 10, result.totals[:paid]
      assert_equal result.totals[:paid], result.attributes[:paid_amount_cents]
    end
  end

  test "blank amount string is not stated on the claim" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-AMT-BLANK")
      claim.update!(paid_amount_cents: 9_999)

      result = Corvid::RemittanceAmounts.call(claim: claim, remittances: [
        remittance(claim_identifier: "CLM-AMT-BLANK", paid_amount: "", adjustment_amount: 5.0)
      ])

      refute_includes result.attributes.keys, :paid_amount_cents
      assert_equal 500, result.attributes[:adjustment_amount_cents]
    end
  end

  test "unparseable amount raises ArgumentError naming the claim and field" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-AMT-PARSE")

      error = assert_raises(ArgumentError) do
        Corvid::RemittanceAmounts.call(claim: claim, remittances: [
          remittance(claim_identifier: "CLM-AMT-PARSE", paid_amount: "n/a",
                     adjustment_codes: [ "CO-97" ])
        ])
      end

      assert_match(/CLM-AMT-PARSE/, error.message)
      assert_match(/paid_amount/, error.message)
      refute_match(/n\/a/, error.message)
      refute_match(/CO-97/, error.message)
    end
  end

  test "Money in the claim currency is summed in cents" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-AMT-MNY")

      result = Corvid::RemittanceAmounts.call(claim: claim, remittances: [
        remittance(claim_identifier: "CLM-AMT-MNY", paid_amount: Money.from_amount(50, "USD"))
      ])

      assert_equal 5000, result.totals[:paid]
      assert_equal 5000, result.attributes[:paid_amount_cents]
    end
  end

  test "Money in a foreign currency raises ArgumentError naming the claim and field" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-AMT-FX")

      error = assert_raises(ArgumentError) do
        Corvid::RemittanceAmounts.call(claim: claim, remittances: [
          remittance(claim_identifier: "CLM-AMT-FX", paid_amount: Money.from_amount(50, "EUR"))
        ])
      end

      assert_match(/CLM-AMT-FX/, error.message)
      assert_match(/paid_amount/, error.message)
    end
  end

  test "leading-decimal and plus-prefixed amount strings parse to cents" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-AMT-EDGE")

      result = Corvid::RemittanceAmounts.call(claim: claim, remittances: [
        remittance(remittance_identifier: "REM-DOT", claim_identifier: "CLM-AMT-EDGE",
                   paid_amount: ".50"),
        remittance(remittance_identifier: "REM-PLUS", payment_date: Date.new(2026, 10, 2),
                   claim_identifier: "CLM-AMT-EDGE", paid_amount: "+50")
      ])

      assert_equal 5050, result.totals[:paid]
      assert_equal 5050, result.attributes[:paid_amount_cents]
    end
  end

  test "ISO-8601 string payment_date orders with Date and Time values" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-AMT-ORDER")

      result = Corvid::RemittanceAmounts.call(claim: claim, remittances: [
        remittance(remittance_identifier: "REM-ISO", payment_date: "2026-10-09",
                   claim_identifier: "CLM-AMT-ORDER", paid_amount: 1.0),
        remittance(remittance_identifier: "REM-TIME", payment_date: Time.utc(2026, 10, 10, 12, 0, 0),
                   claim_identifier: "CLM-AMT-ORDER", paid_amount: 0, status: "denied",
                   adjustment_codes: [ "CO-16" ])
      ])

      assert_equal "denied", result.latest_line[:status].to_s
      assert_equal %w[CO-16], Array(result.latest_line[:adjustment_codes]).map(&:to_s)
    end
  end

  private

  def create_claim(claim_identifier)
    Corvid::ClaimSubmission.create!(
      patient_identifier: "pt_remit_amt",
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
end
