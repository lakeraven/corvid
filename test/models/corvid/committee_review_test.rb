# frozen_string_literal: true

require "test_helper"

class Corvid::CommitteeReviewTest < ActiveSupport::TestCase
  TENANT = "tnt_cr_test"

  setup do
    Corvid::CommitteeReview.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # CREATION & DEFAULTS
  # =============================================================================

  test "creates with referral and pending decision" do
    with_tenant(TENANT) do
      review = create_review
      assert review.persisted?
      assert review.pending?
    end
  end

  test "defaults decision to pending" do
    with_tenant(TENANT) do
      review = create_review
      assert_equal "pending", review.decision
    end
  end

  test "requires prc_referral" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(committee_date: Date.current)
      refute review.valid?
    end
  end

  # =============================================================================
  # DECISION ENUM
  # =============================================================================

  test "decision enum includes expected values" do
    expected = %w[pending approved denied deferred modified]
    assert_equal expected.sort, Corvid::CommitteeReview.decisions.keys.sort
  end

  test "can approve" do
    with_tenant(TENANT) do
      review = create_review
      review.approved!
      assert review.approved?
    end
  end

  test "can deny" do
    with_tenant(TENANT) do
      review = create_review
      review.denied!
      assert review.denied?
    end
  end

  test "can defer" do
    with_tenant(TENANT) do
      review = create_review
      review.deferred!
      assert review.deferred?
    end
  end

  test "can modify" do
    with_tenant(TENANT) do
      review = create_review
      review.modified!
      assert review.modified?
    end
  end

  # =============================================================================
  # PREDICATES
  # =============================================================================

  test "finalized? false when pending" do
    with_tenant(TENANT) do
      refute create_review.finalized?
    end
  end

  test "finalized? true when approved" do
    with_tenant(TENANT) do
      review = create_review
      review.approved!
      assert review.finalized?
    end
  end

  test "finalized? true when denied" do
    with_tenant(TENANT) do
      review = create_review
      review.denied!
      assert review.finalized?
    end
  end

  test "finalized? true when deferred" do
    with_tenant(TENANT) do
      review = create_review
      review.deferred!
      assert review.finalized?
    end
  end

  test "finalized? true when modified" do
    with_tenant(TENANT) do
      review = create_review
      review.modified!
      assert review.finalized?
    end
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "upcoming returns pending reviews with future date" do
    with_tenant(TENANT) do
      upcoming = create_review(committee_date: 1.week.from_now)
      past = create_review(committee_date: 1.week.ago)

      assert_includes Corvid::CommitteeReview.upcoming, upcoming
      refute_includes Corvid::CommitteeReview.upcoming, past
    end
  end

  test "upcoming excludes decided reviews" do
    with_tenant(TENANT) do
      upcoming_pending = create_review(committee_date: 1.day.from_now)
      upcoming_approved = create_review(committee_date: 1.day.from_now)
      upcoming_approved.approved!

      assert_includes Corvid::CommitteeReview.upcoming, upcoming_pending
      refute_includes Corvid::CommitteeReview.upcoming, upcoming_approved
    end
  end

  test "finalized returns non-pending reviews" do
    with_tenant(TENANT) do
      pending_review = create_review
      approved_review = create_review
      approved_review.approved!

      refute_includes Corvid::CommitteeReview.finalized, pending_review
      assert_includes Corvid::CommitteeReview.finalized, approved_review
    end
  end

  # =============================================================================
  # AMOUNTS
  # =============================================================================

  test "stores requested_amount" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(requested_amount: 100_000, approved_amount: 75_000, decision: :modified)
      review.reload
      assert_equal 100_000, review.requested_amount.to_i
      assert_equal 75_000, review.approved_amount.to_i
    end
  end

  test "stores approved_amount" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(approved_amount: 50_000, decision: :approved)
      review.reload
      assert_equal 50_000, review.approved_amount.to_i
    end
  end

  # =============================================================================
  # APPEAL DEADLINE
  # =============================================================================

  test "stores appeal_deadline" do
    with_tenant(TENANT) do
      deadline = Date.current + 30.days
      review = create_review
      review.update!(decision: :denied, appeal_deadline: deadline)
      review.reload
      assert_equal deadline, review.appeal_deadline
    end
  end

  # =============================================================================
  # REVIEWER
  # =============================================================================

  test "stores reviewer_identifier" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(reviewer_identifier: "pr_101")
      review.reload
      assert_equal "pr_101", review.reviewer_identifier
    end
  end

  # =============================================================================
  # APPLY TO REFERRAL
  # =============================================================================

  test "apply_to_referral! does nothing when pending" do
    with_tenant(TENANT) do
      review = create_review
      referral = review.prc_referral
      original_status = referral.status
      review.apply_to_referral!
      referral.reload
      assert_equal original_status, referral.status
    end
  end

  test "apply_to_referral! authorizes when approved" do
    with_tenant(TENANT) do
      referral = create_referral_in_committee_review
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral,
        committee_date: Date.current,
        decision: :approved,
        approved_amount: 75_000
      )
      review.apply_to_referral!
      referral.reload
      assert_equal "authorized", referral.status
    end
  end

  test "apply_to_referral! denies when denied" do
    with_tenant(TENANT) do
      referral = create_referral_in_committee_review
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral,
        committee_date: Date.current,
        decision: :denied
      )
      review.apply_to_referral!
      referral.reload
      assert_equal "denied", referral.status
    end
  end

  test "apply_to_referral! defers when deferred" do
    with_tenant(TENANT) do
      referral = create_referral_in_committee_review
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral,
        committee_date: Date.current,
        decision: :deferred
      )
      review.apply_to_referral!
      referral.reload
      assert_equal "deferred", referral.status
    end
  end

  test "apply_to_referral! authorizes when modified" do
    with_tenant(TENANT) do
      referral = create_referral_in_committee_review
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral,
        committee_date: Date.current,
        decision: :modified,
        approved_amount: 40_000
      )
      review.apply_to_referral!
      referral.reload
      assert_equal "authorized", referral.status
    end
  end

  # =============================================================================
  # MULTI-TENANCY
  # =============================================================================

  test "reviews are scoped to current tenant" do
    my_review = nil
    other_review = nil

    with_tenant("tenant_a") do
      my_review = create_review
    end

    with_tenant("tenant_b") do
      other_review = create_review
    end

    with_tenant("tenant_a") do
      assert_includes Corvid::CommitteeReview.all, my_review
      refute_includes Corvid::CommitteeReview.all, other_review
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: "pt_cr_test",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_referral(**attrs)
    Corvid::PrcReferral.create!(
      case: create_case,
      referral_identifier: "ref_#{SecureRandom.hex(4)}",
      **attrs
    )
  end

  def create_referral_in_committee_review
    referral = create_referral(estimated_cost: 75_000, medical_priority: 3)
    referral.submit!
    # Skip to committee_review by setting status directly for test purposes
    referral.update_column(:status, "committee_review")
    referral.reload
    referral
  end

  def create_review(committee_date: Date.current, **attrs)
    Corvid::CommitteeReview.create!(
      prc_referral: attrs.delete(:prc_referral) || create_referral,
      committee_date: committee_date,
      **attrs
    )
  end
end
