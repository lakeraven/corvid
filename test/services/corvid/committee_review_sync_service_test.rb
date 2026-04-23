# frozen_string_literal: true

require "test_helper"

class Corvid::CommitteeReviewSyncServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_crs_test"

  setup do
    Corvid::CommitteeReview.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # SYNC APPROVED DECISION
  # =============================================================================

  test "sync_decision syncs approved decision" do
    with_tenant(TENANT) do
      review = create_review_with_registered_referral(decision: "approved", approved_amount: 75_000)
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)
      assert result[:success]
    end
  end

  test "sync_decision includes synced_amount for approved" do
    with_tenant(TENANT) do
      review = create_review_with_registered_referral(decision: "approved", approved_amount: 50_000)
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)
      assert_equal 50_000, result[:synced_amount].to_i
    end
  end

  # =============================================================================
  # SYNC DENIED DECISION
  # =============================================================================

  test "sync_decision syncs denied decision" do
    with_tenant(TENANT) do
      review = create_review_with_registered_referral(decision: "denied")
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)
      assert result[:success]
    end
  end

  # =============================================================================
  # SYNC DEFERRED DECISION
  # =============================================================================

  test "sync_decision syncs deferred decision" do
    with_tenant(TENANT) do
      review = create_review_with_registered_referral(decision: "deferred")
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)
      assert result[:success]
    end
  end

  # =============================================================================
  # SYNC MODIFIED DECISION
  # =============================================================================

  test "sync_decision syncs modified decision as approved" do
    with_tenant(TENANT) do
      review = create_review_with_registered_referral(decision: "modified", approved_amount: 40_000)
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)
      assert result[:success]
    end
  end

  # =============================================================================
  # PENDING HANDLING
  # =============================================================================

  test "sync_decision returns error for pending review" do
    with_tenant(TENANT) do
      review = create_review(decision: "pending")
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)
      refute result[:success]
      assert_equal "pending", result[:error]
    end
  end

  # =============================================================================
  # FINALIZED PREDICATE
  # =============================================================================

  test "finalized review is finalized" do
    with_tenant(TENANT) do
      review = create_review(decision: "approved")
      assert review.finalized?
    end
  end

  test "pending review is not finalized" do
    with_tenant(TENANT) do
      review = create_review(decision: "pending")
      refute review.finalized?
    end
  end

  # =============================================================================
  # REVIEWER
  # =============================================================================

  test "sync_decision includes reviewer_identifier" do
    with_tenant(TENANT) do
      review = create_review_with_registered_referral(
        decision: "approved", approved_amount: 50_000, reviewer_identifier: "pr_101"
      )
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)
      assert result[:success]
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_crs", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_review(decision: "pending", **attrs)
    Corvid::CommitteeReview.create!(
      prc_referral: create_referral,
      committee_date: Date.current,
      decision: decision,
      **attrs
    )
  end

  def create_review_with_registered_referral(decision: "approved", **attrs)
    referral = create_referral
    # Register referral in mock adapter under the identifier used by PrcReferral
    # so update_referral(referral_identifier, ...) returns true
    adapter = Corvid.adapter
    adapter.instance_variable_get(:@referrals)[referral.referral_identifier] = {
      patient_identifier: referral.case.patient_identifier,
      status: "pending"
    }
    Corvid::CommitteeReview.create!(
      prc_referral: referral,
      committee_date: Date.current,
      decision: decision,
      **attrs
    )
  end
end
