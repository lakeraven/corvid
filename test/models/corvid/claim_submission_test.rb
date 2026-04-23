# frozen_string_literal: true

require "test_helper"

class Corvid::ClaimSubmissionTest < ActiveSupport::TestCase
  TENANT = "tnt_cs_test"

  setup do
    Corvid::ClaimSubmission.unscoped.delete_all
  end

  # =============================================================================
  # CREATION & DEFAULTS
  # =============================================================================

  test "creates with required fields" do
    with_tenant(TENANT) do
      claim = create_claim
      assert claim.persisted?
    end
  end

  test "defaults status to draft" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        patient_identifier: "pt_1",
        claim_type: "professional",
        service_date: Date.current
      )
      assert_equal "draft", claim.status
    end
  end

  test "defaults claim_type to professional" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        patient_identifier: "pt_1",
        service_date: Date.current
      )
      assert_equal "professional", claim.claim_type
    end
  end

  # =============================================================================
  # VALIDATIONS
  # =============================================================================

  test "requires patient_identifier" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(claim_type: "professional")
      refute claim.valid?
      assert claim.errors[:patient_identifier].any?
    end
  end

  test "requires valid claim_type" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(patient_identifier: "pt_1", claim_type: "bogus")
      refute claim.valid?
    end
  end

  test "accepts all valid claim types" do
    with_tenant(TENANT) do
      Corvid::ClaimSubmission::CLAIM_TYPES.each do |type|
        claim = Corvid::ClaimSubmission.new(
          patient_identifier: "pt_1",
          claim_type: type,
          service_date: Date.current
        )
        assert claim.valid?, "Should accept type: #{type}"
      end
    end
  end

  test "requires valid status" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(
        patient_identifier: "pt_1",
        claim_type: "professional",
        status: "bogus"
      )
      refute claim.valid?
    end
  end

  test "accepts all valid statuses" do
    with_tenant(TENANT) do
      Corvid::ClaimSubmission::STATUSES.each do |status|
        claim = Corvid::ClaimSubmission.new(
          patient_identifier: "pt_1",
          claim_type: "professional",
          status: status,
          service_date: Date.current
        )
        assert claim.valid?, "Should accept status: #{status}"
      end
    end
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "pending scope returns submitted and accepted" do
    with_tenant(TENANT) do
      submitted = create_claim(status: "submitted")
      accepted = create_claim(status: "accepted")
      paid = create_claim(status: "paid")
      draft = create_claim(status: "draft")

      pending = Corvid::ClaimSubmission.pending
      assert_includes pending, submitted
      assert_includes pending, accepted
      refute_includes pending, paid
      refute_includes pending, draft
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

  test "rejected scope returns rejected and denied" do
    with_tenant(TENANT) do
      rejected = create_claim(status: "rejected")
      denied = create_claim(status: "denied")
      paid = create_claim(status: "paid")

      result = Corvid::ClaimSubmission.rejected
      assert_includes result, rejected
      assert_includes result, denied
      refute_includes result, paid
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

  test "for_referral scope" do
    with_tenant(TENANT) do
      mine = create_claim(referral_identifier: "ref_1")
      other = create_claim(referral_identifier: "ref_2")

      assert_includes Corvid::ClaimSubmission.for_referral("ref_1"), mine
      refute_includes Corvid::ClaimSubmission.for_referral("ref_1"), other
    end
  end

  test "in_date_range scope" do
    with_tenant(TENANT) do
      jan = create_claim(service_date: Date.new(2026, 1, 15))
      mar = create_claim(service_date: Date.new(2026, 3, 15))

      q1 = Corvid::ClaimSubmission.in_date_range(Date.new(2026, 1, 1)..Date.new(2026, 3, 31))
      assert_includes q1, jan
      assert_includes q1, mar
    end
  end

  test "needs_status_check scope" do
    with_tenant(TENANT) do
      stale = create_claim(status: "submitted")
      stale.update!(last_checked_at: 2.hours.ago)

      fresh = create_claim(status: "submitted")
      fresh.update!(last_checked_at: 30.minutes.ago)

      needs_check = Corvid::ClaimSubmission.needs_status_check(1.hour)
      assert_includes needs_check, stale
      refute_includes needs_check, fresh
    end
  end

  # =============================================================================
  # CALCULATIONS
  # =============================================================================

  test "balance_due calculates remaining" do
    with_tenant(TENANT) do
      claim = create_claim(billed_amount: 500.0, paid_amount: 300.0, adjustment_amount: 50.0)
      assert_in_delta 150.0, claim.balance_due
    end
  end

  test "balance_due with nil amounts" do
    with_tenant(TENANT) do
      claim = create_claim(billed_amount: 500.0)
      assert_in_delta 500.0, claim.balance_due
    end
  end

  test "total_adjustment sums adjustment and patient_responsibility" do
    with_tenant(TENANT) do
      claim = create_claim(adjustment_amount: 50.0, patient_responsibility: 25.0)
      assert_in_delta 75.0, claim.total_adjustment
    end
  end

  # =============================================================================
  # MULTI-TENANCY
  # =============================================================================

  test "claims scoped to tenant" do
    mine = nil
    other = nil

    with_tenant("tenant_a") do
      mine = create_claim
    end

    with_tenant("tenant_b") do
      other = create_claim
    end

    with_tenant("tenant_a") do
      assert_includes Corvid::ClaimSubmission.all, mine
      refute_includes Corvid::ClaimSubmission.all, other
    end
  end

  private

  def create_claim(patient_identifier: "pt_cs", status: "submitted", **attrs)
    Corvid::ClaimSubmission.create!(
      patient_identifier: patient_identifier,
      claim_type: attrs.delete(:claim_type) || "professional",
      service_date: attrs.delete(:service_date) || Date.current,
      status: status,
      billed_amount: attrs.delete(:billed_amount) || 100.0,
      **attrs
    )
  end
end
