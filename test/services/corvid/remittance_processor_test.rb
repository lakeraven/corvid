# frozen_string_literal: true

require "minitest/mock"
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

  # --- Issue #681: full remittance history, status ordering, amounts --------

  class HistoryAdapter < Struct.new(:history, keyword_init: true)
    def fetch_remittances(date_range: nil)
      history
    end
  end

  class UnknownHistoryAdapter
    def fetch_remittances(date_range: nil)
      nil
    end
  end

  test "sums adapter history and batch for each claim per ReferralBillingReconciliation read" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-HIST-1")
      history = [
        remittance(remittance_identifier: "REM-P1", payment_date: Date.new(2026, 10, 1),
                   claim_identifier: "CLM-R-HIST-1", paid_amount: 250.0)
      ]
      batch = [
        remittance(remittance_identifier: "REM-REV", payment_date: Date.new(2026, 10, 2),
                   claim_identifier: "CLM-R-HIST-1", paid_amount: -250.0),
        remittance(remittance_identifier: "REM-COR", payment_date: Date.new(2026, 10, 3),
                   claim_identifier: "CLM-R-HIST-1", paid_amount: 200.0)
      ]
      adapter = HistoryAdapter.new(history: history)

      call_processor(batch, adapter: adapter)

      claim.reload
      assert_equal 20_000, claim.paid_amount_cents
      refute_equal(-5_000, claim.paid_amount_cents)
    end
  end

  test "adapter history and batch amounts add for the same claim" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-HIST-2")
      adapter = HistoryAdapter.new(history: [
        remittance(remittance_identifier: "REM-HIST", payment_date: Date.new(2026, 10, 1),
                   claim_identifier: "CLM-R-HIST-2", paid_amount: 250.0)
      ])

      call_processor([
        remittance(remittance_identifier: "REM-BATCH", payment_date: Date.new(2026, 10, 2),
                   claim_identifier: "CLM-R-HIST-2", paid_amount: 50.0)
      ], adapter: adapter)

      claim.reload
      assert_equal 30_000, claim.paid_amount_cents
    end
  end

  test "unknown remittance history leaves batch claims unchanged and counts unknown" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-UNK")
      claim.update!(paid_amount_cents: 12_345, status: "accepted")

      result = call_processor([
        remittance(claim_identifier: "CLM-R-UNK", paid_amount: 99.0)
      ], adapter: UnknownHistoryAdapter.new)

      claim.reload
      assert_equal 12_345, claim.paid_amount_cents
      assert_equal "accepted", claim.status
      assert result.is_a?(Struct) && result.members.include?(:unknown),
        "Result must expose unknown count when remittance history is unknown"
      assert_equal 1, result.unknown
      assert_equal 0, result.paid
    end
  end

  test "injected adapter is used instead of Corvid.adapter global" do
    with_tenant(TENANT) do
      create_claim("CLM-R-INJ")
      recording = HistoryAdapter.new(history: [])
      recording.define_singleton_method(:fetch_remittances) do |**|
        @fetch_calls = (@fetch_calls || 0) + 1
        history
      end

      Corvid.adapter.stub(:fetch_remittances, -> { raise "must not use global adapter" }) do
        call_processor([
          remittance(claim_identifier: "CLM-R-INJ", paid_amount: 1.0)
        ], adapter: recording)
      end

      assert_equal 1, recording.instance_variable_get(:@fetch_calls)
    end
  end

  test "claim line item with surrounding whitespace matches the trimmed claim" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-WS")

      result = Corvid::RemittanceProcessor.call([
        remittance(claim_identifier: " CLM-R-WS ", paid_amount: 100.0)
      ])

      claim.reload
      assert claim.paid?
      assert_equal 10_000, claim.paid_amount_cents
      assert_equal 1, result.paid
    end
  end

  test "zero-paid line after a payment does not change paid status" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-ZERO-STAT")

      Corvid::RemittanceProcessor.call([
        remittance(remittance_identifier: "REM-PAID", payment_date: Date.new(2026, 9, 1),
                   claim_identifier: "CLM-R-ZERO-STAT", paid_amount: 500.0),
        remittance(remittance_identifier: "REM-ZERO", payment_date: Date.new(2026, 10, 1),
                   claim_identifier: "CLM-R-ZERO-STAT", paid_amount: 0.0)
      ])

      claim.reload
      assert claim.paid?
      assert_equal 50_000, claim.paid_amount_cents
    end
  end

  test "undated denial after a dated payment decides status" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-UND-DENY")

      Corvid::RemittanceProcessor.call([
        remittance(remittance_identifier: "REM-R1", payment_date: Date.new(2026, 10, 1),
                   claim_identifier: "CLM-R-UND-DENY", paid_amount: 100.0),
        remittance(remittance_identifier: "REM-R2", payment_date: nil,
                   claim_identifier: "CLM-R-UND-DENY", paid_amount: 0, status: "denied",
                   adjustment_codes: [ "CO-97" ])
      ])

      claim.reload
      assert claim.denied?
      assert_equal %w[CO-97], claim.denial_reason_codes
    end
  end

  test "non-ISO payment_date is undated and sorts after ISO dated lines" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-UND-DATE")

      Corvid::RemittanceProcessor.call([
        remittance(remittance_identifier: "REM-R1", payment_date: Date.new(2026, 10, 9),
                   claim_identifier: "CLM-R-UND-DATE", paid_amount: 10.0),
        remittance(remittance_identifier: "REM-R2", payment_date: "10/10/2026",
                   claim_identifier: "CLM-R-UND-DATE", paid_amount: 0, status: "denied",
                   adjustment_codes: [ "CO-45" ])
      ])

      claim.reload
      assert claim.denied?
    end
  end

  test "paid_date comes only from the latest dated line when a later line is undated" do
    with_tenant(TENANT) do
      claim = create_claim("CLM-R-PDATE-UND")

      Corvid::RemittanceProcessor.call([
        remittance(remittance_identifier: "REM-DATED", payment_date: Date.new(2026, 9, 1),
                   claim_identifier: "CLM-R-PDATE-UND", paid_amount: 50.0),
        remittance(remittance_identifier: "REM-UND-ADD", payment_date: nil,
                   claim_identifier: "CLM-R-PDATE-UND", paid_amount: 10.0)
      ])

      claim.reload
      assert_equal Date.new(2026, 9, 1), claim.paid_date
      assert_equal 6_000, claim.paid_amount_cents
    end
  end

  test "unparseable amount aborts the batch without writing any claim" do
    with_tenant(TENANT) do
      ok_claim = create_claim("CLM-R-AMT-OK")
      create_claim("CLM-R-AMT-BAD")

      error = assert_raises(ArgumentError) do
        Corvid::RemittanceProcessor.call([
          remittance(claim_identifier: "CLM-R-AMT-OK", paid_amount: 25.0),
          remittance(claim_identifier: "CLM-R-AMT-BAD", paid_amount: "n/a")
        ])
      end

      assert_match(/CLM-R-AMT-BAD/, error.message)
      assert_match(/paid_amount/, error.message)
      refute_match(/n\/a/, error.message)
      refute_match(/CLM-R-AMT-OK/, error.message)

      ok_claim.reload
      assert_nil ok_claim.paid_amount_cents
      assert_equal "accepted", ok_claim.status
    end
  end

  private

  def call_processor(remittances, adapter: Corvid.adapter)
    unless Corvid::RemittanceProcessor.method(:call).parameters.any? { |(_, name)| name == :adapter }
      flunk "RemittanceProcessor.call must accept adapter: keyword (ADR 0005)"
    end

    Corvid::RemittanceProcessor.call(remittances, adapter: adapter)
  end

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
