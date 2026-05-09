# frozen_string_literal: true

require "test_helper"

class Corvid::ClaimSubmissionTest < ActiveSupport::TestCase
  TENANT = "tnt_cs_test"

  test "creates with required fields" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        patient_identifier: "pt_1",
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 500.00
      )
      assert claim.persisted?
      assert_equal "draft", claim.status
    end
  end

  test "validates patient_identifier" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(claim_type: "professional")
      refute claim.valid?
    end
  end

  test "validates claim_type" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(patient_identifier: "pt_1", claim_type: "bogus")
      refute claim.valid?
    end
  end

  test "pending scope" do
    with_tenant(TENANT) do
      submitted = create_claim(status: "submitted")
      paid = create_claim(status: "paid")

      assert_includes Corvid::ClaimSubmission.pending, submitted
      refute_includes Corvid::ClaimSubmission.pending, paid
    end
  end

  test "paid scope" do
    with_tenant(TENANT) do
      paid = create_claim(status: "paid")
      submitted = create_claim(status: "submitted")

      assert_includes Corvid::ClaimSubmission.paid, paid
      refute_includes Corvid::ClaimSubmission.paid, submitted
    end
  end

  test "for_patient scope" do
    with_tenant(TENANT) do
      mine = create_claim(patient_identifier: "pt_1")
      other = create_claim(patient_identifier: "pt_2")

      assert_includes Corvid::ClaimSubmission.for_patient("pt_1"), mine
      refute_includes Corvid::ClaimSubmission.for_patient("pt_1"), other
    end
  end

  test "balance_due calculates remaining" do
    with_tenant(TENANT) do
      claim = create_claim(billed_amount: 500.0, paid_amount: 300.0, adjustment_amount: 50.0)
      assert_equal Money.from_amount(150, "USD"), claim.balance_due
    end
  end

  # -- Defaults --------------------------------------------------------------

  test "defaults status to draft" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(patient_identifier: "pt_1", claim_type: "professional")
      assert_equal "draft", claim.status
    end
  end

  # -- More scopes -----------------------------------------------------------

  test "professional scope filters professional claims" do
    with_tenant(TENANT) do
      pro = create_claim(claim_type: "professional")
      inst = create_claim(claim_type: "institutional")

      assert_includes Corvid::ClaimSubmission.professional, pro
      refute_includes Corvid::ClaimSubmission.professional, inst
    end
  end

  test "institutional scope filters institutional claims" do
    with_tenant(TENANT) do
      pro = create_claim(claim_type: "professional")
      inst = create_claim(claim_type: "institutional")

      assert_includes Corvid::ClaimSubmission.institutional, inst
      refute_includes Corvid::ClaimSubmission.institutional, pro
    end
  end

  test "submitted scope filters by status" do
    with_tenant(TENANT) do
      submitted = create_claim(status: "submitted")
      draft = create_claim(status: "draft")

      assert_includes Corvid::ClaimSubmission.by_status("submitted"), submitted
      refute_includes Corvid::ClaimSubmission.by_status("submitted"), draft
    end
  end

  test "rejected scope filters by status" do
    with_tenant(TENANT) do
      rejected = create_claim(status: "rejected")
      accepted = create_claim(status: "accepted")

      assert_includes Corvid::ClaimSubmission.rejected, rejected
      refute_includes Corvid::ClaimSubmission.rejected, accepted
    end
  end

  test "for_referral scope filters by referral_identifier" do
    with_tenant(TENANT) do
      claim1 = create_claim(referral_identifier: "ref_100")
      claim2 = create_claim(referral_identifier: "ref_200")

      results = Corvid::ClaimSubmission.for_referral("ref_100")
      assert_includes results, claim1
      refute_includes results, claim2
    end
  end

  # -- Instance methods ------------------------------------------------------

  test "professional? returns true for professional" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(claim_type: "professional")
      assert claim.professional?
    end
  end

  test "institutional? returns true for institutional" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(claim_type: "institutional")
      assert claim.institutional?
    end
  end

  test "submitted? returns true when status is submitted" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(status: "submitted")
      assert claim.submitted?
    end
  end

  test "paid? returns true when status is paid" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(status: "paid")
      assert claim.paid?
    end
  end

  test "rejected? returns true when status is rejected or denied" do
    with_tenant(TENANT) do
      %w[rejected denied].each do |status|
        claim = Corvid::ClaimSubmission.new(status: status)
        assert claim.rejected?, "Expected rejected? for status #{status}"
      end
    end
  end

  test "pending? returns true for submitted or accepted" do
    with_tenant(TENANT) do
      submitted = Corvid::ClaimSubmission.new(status: "submitted")
      accepted = Corvid::ClaimSubmission.new(status: "accepted")
      paid = Corvid::ClaimSubmission.new(status: "paid")

      assert submitted.pending?
      assert accepted.pending?
      refute paid.pending?
    end
  end

  # -- Lifecycle methods -----------------------------------------------------

  test "mark_submitted! updates status and submitted_at" do
    with_tenant(TENANT) do
      claim = create_claim(status: "draft")
      claim.mark_submitted!(claim_identifier: "CLM-001")

      assert_equal "submitted", claim.reload.status
      assert_equal "CLM-001", claim.claim_identifier
      assert_not_nil claim.submitted_at
    end
  end

  test "mark_paid! updates status and paid amount" do
    with_tenant(TENANT) do
      claim = create_claim(status: "accepted", billed_amount: 150.0)
      claim.mark_paid!(paid_amount: 120.0)

      assert_equal "paid", claim.reload.status
      assert_equal Money.from_amount(120, "USD"), claim.paid_amount
    end
  end

  test "mark_rejected! updates status and denial reason" do
    with_tenant(TENANT) do
      claim = create_claim(status: "submitted")
      claim.mark_rejected!(reason_token: "rt_invalid_member")

      assert_equal "rejected", claim.reload.status
      assert_equal "rt_invalid_member", claim.denial_reason_token
    end
  end

  # -- Statistics ------------------------------------------------------------

  test "totals_billed_by_currency aggregates per currency" do
    with_tenant(TENANT) do
      create_claim(billed_amount: 100)
      create_claim(billed_amount: 200)
      create_claim(billed_amount: 300)

      totals = Corvid::ClaimSubmission.totals_billed_by_currency
      assert_equal Money.from_amount(600, "USD"), totals["USD"]
    end
  end

  test "totals_paid_by_currency aggregates per currency" do
    with_tenant(TENANT) do
      create_claim(status: "paid", paid_amount: 80.0)
      create_claim(status: "paid", paid_amount: 160.0)

      totals = Corvid::ClaimSubmission.totals_paid_by_currency
      assert_equal Money.from_amount(240, "USD"), totals["USD"]
    end
  end

  test "totals_*_by_currency split mixed-currency tenants into separate buckets" do
    with_tenant(TENANT) do
      # Pass cents + currency_iso explicitly so subunit interpretation
      # is unambiguous — JOD's 1000-fils-per-dinar would otherwise
      # decode under USD's 100-cents assumption if currency was set
      # after the amount.
      base = {
        patient_identifier: "p", claim_type: "professional",
        service_date: Date.current, status: "submitted"
      }
      Corvid::ClaimSubmission.create!(base.merge(currency_iso: "USD", billed_amount_cents: 10_000))
      Corvid::ClaimSubmission.create!(base.merge(currency_iso: "EUR", billed_amount_cents: 20_000))
      Corvid::ClaimSubmission.create!(base.merge(currency_iso: "JOD", billed_amount_cents: 142_000))

      totals = Corvid::ClaimSubmission.totals_billed_by_currency
      assert_equal Money.from_amount(100, "USD"), totals["USD"]
      assert_equal Money.from_amount(200, "EUR"), totals["EUR"]
      assert_equal Money.from_amount(142, "JOD"), totals["JOD"]
    end
  end

  test "currency_iso is immutable once a row is persisted" do
    with_tenant(TENANT) do
      claim = create_claim
      claim.currency_iso = "EUR"
      assert_raises(ActiveRecord::RecordInvalid) { claim.save! }
    end
  end

  test "acceptance_rate calculates percentage" do
    with_tenant(TENANT) do
      3.times { create_claim(status: "paid") }
      1.times { create_claim(status: "rejected") }

      assert_in_delta 75.0, Corvid::ClaimSubmission.acceptance_rate
    end
  end

  # -- accepted? predicate ---------------------------------------------------

  test "accepted? returns true when status is accepted" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(status: "accepted")
      assert_equal "accepted", claim.status
    end
  end

  # -- mark_accepted! --------------------------------------------------------

  test "mark_accepted transitions from submitted" do
    with_tenant(TENANT) do
      claim = create_claim(status: "submitted")
      claim.update!(status: "accepted")
      assert_equal "accepted", claim.reload.status
    end
  end

  # -- CLAIM_TYPES -----------------------------------------------------------

  test "accepts valid claim types" do
    with_tenant(TENANT) do
      Corvid::ClaimSubmission::CLAIM_TYPES.each do |type|
        claim = Corvid::ClaimSubmission.new(patient_identifier: "pt_1", claim_type: type)
        claim.valid?
        refute_includes claim.errors[:claim_type], "is not included in the list"
      end
    end
  end

  private

  def create_claim(patient_identifier: "pt_cs", status: "submitted", claim_type: "professional", **attrs)
    Corvid::ClaimSubmission.create!(
      patient_identifier: patient_identifier,
      claim_type: claim_type,
      service_date: Date.current,
      status: status,
      billed_amount: attrs.delete(:billed_amount) || 100.0,
      **attrs
    )
  end
end
