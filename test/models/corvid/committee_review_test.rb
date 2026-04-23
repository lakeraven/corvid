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
  # VALIDATIONS
  # =============================================================================

  test "requires committee_date" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: nil)
      refute review.valid?
      assert review.errors[:committee_date].any?
    end
  end

  test "requires rationale_token when denied" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :denied,
        rationale_token: nil
      )
      refute review.valid?
      assert review.errors[:rationale_token].any?
    end
  end

  test "requires rationale_token when deferred" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :deferred,
        rationale_token: nil
      )
      refute review.valid?
      assert review.errors[:rationale_token].any?
    end
  end

  test "requires approved_amount when approved" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :approved,
        approved_amount: nil
      )
      refute review.valid?
      assert review.errors[:approved_amount].any?
    end
  end

  test "requires approved_amount when modified" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :modified,
        approved_amount: nil
      )
      refute review.valid?
      assert review.errors[:approved_amount].any?
    end
  end

  test "requires appeal_instructions_token when denied" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :denied,
        rationale_token: "tok_test",
        appeal_instructions_token: nil
      )
      refute review.valid?
      assert review.errors[:appeal_instructions_token].any?
    end
  end

  test "valid denial with all required fields" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :denied,
        rationale_token: "tok_rationale",
        appeal_instructions_token: "tok_appeal"
      )
      assert review.valid?
    end
  end

  test "valid approval with amount" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :approved,
        approved_amount: 75_000
      )
      assert review.valid?
    end
  end

  # =============================================================================
  # PREDICATES (ported from rpms_redux)
  # =============================================================================

  test "approved_or_modified? true for approved" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :approved, approved_amount: 50_000)
      assert review.approved_or_modified?
    end
  end

  test "approved_or_modified? true for modified" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :modified, approved_amount: 40_000)
      assert review.approved_or_modified?
    end
  end

  test "approved_or_modified? false for denied" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :denied, rationale_token: "t", appeal_instructions_token: "t")
      refute review.approved_or_modified?
    end
  end

  test "requires_followup? true for deferred" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :deferred, rationale_token: "t")
      assert review.requires_followup?
    end
  end

  test "requires_followup? true for modified" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :modified, approved_amount: 40_000)
      assert review.requires_followup?
    end
  end

  test "requires_followup? false for approved" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :approved, approved_amount: 50_000)
      refute review.requires_followup?
    end
  end

  # =============================================================================
  # CALLBACKS
  # =============================================================================

  test "sets appeal_deadline when denied and not already set" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.create!(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :denied,
        rationale_token: "tok_r",
        appeal_instructions_token: "tok_a"
      )
      assert_equal Date.current + 30.days, review.appeal_deadline
    end
  end

  test "does not override custom appeal_deadline" do
    with_tenant(TENANT) do
      custom = Date.current + 45.days
      review = Corvid::CommitteeReview.create!(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :denied,
        rationale_token: "tok_r",
        appeal_instructions_token: "tok_a",
        appeal_deadline: custom
      )
      assert_equal custom, review.appeal_deadline
    end
  end

  # =============================================================================
  # DECISION SUMMARY
  # =============================================================================

  test "decision_summary for pending" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :pending)
      assert_includes review.decision_summary, "Pending"
    end
  end

  test "decision_summary for approved includes amount" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :approved, approved_amount: 50_000)
      assert_includes review.decision_summary, "Approved"
      assert_includes review.decision_summary, "50000"
    end
  end

  test "decision_summary for denied" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :denied, rationale_token: "t", appeal_instructions_token: "t")
      assert_includes review.decision_summary, "Denied"
    end
  end

  test "decision_summary for modified includes amount" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(prc_referral: create_referral, committee_date: Date.current, decision: :modified, approved_amount: 40_000)
      assert_includes review.decision_summary, "Approved with modifications"
    end
  end

  # =============================================================================
  # SCOPES (additional)
  # =============================================================================

  test "chronological orders by committee_date asc" do
    with_tenant(TENANT) do
      r1 = create_review(committee_date: 3.days.ago)
      r2 = create_review(committee_date: 1.day.ago)
      r3 = create_review(committee_date: 2.days.ago)

      ordered = Corvid::CommitteeReview.chronological
      assert_equal [r1, r3, r2], ordered.to_a
    end
  end

  test "reverse_chronological orders by committee_date desc" do
    with_tenant(TENANT) do
      r1 = create_review(committee_date: 3.days.ago)
      r2 = create_review(committee_date: 1.day.ago)

      ordered = Corvid::CommitteeReview.reverse_chronological
      assert_equal r2, ordered.first
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
      review.update!(decision: :approved, approved_amount: 50_000)
      assert review.approved?
    end
  end

  test "can deny" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :denied, rationale_token: "tok_r", appeal_instructions_token: "tok_a")
      assert review.denied?
    end
  end

  test "can defer" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :deferred, rationale_token: "tok_r")
      assert review.deferred?
    end
  end

  test "can modify" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :modified, approved_amount: 40_000)
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
      review.update!(decision: :approved, approved_amount: 50_000)
      assert review.finalized?
    end
  end

  test "finalized? true when denied" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :denied, rationale_token: "tok_r", appeal_instructions_token: "tok_a")
      assert review.finalized?
    end
  end

  test "finalized? true when deferred" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :deferred, rationale_token: "tok_r")
      assert review.finalized?
    end
  end

  test "finalized? true when modified" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :modified, approved_amount: 40_000)
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
      upcoming_approved.update!(decision: :approved, approved_amount: 50_000)

      assert_includes Corvid::CommitteeReview.upcoming, upcoming_pending
      refute_includes Corvid::CommitteeReview.upcoming, upcoming_approved
    end
  end

  test "finalized returns non-pending reviews" do
    with_tenant(TENANT) do
      pending_review = create_review
      approved_review = create_review
      approved_review.update!(decision: :approved, approved_amount: 50_000)

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
      review.update!(decision: :denied, appeal_deadline: deadline, rationale_token: "tok_r", appeal_instructions_token: "tok_a")
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
        decision: :denied,
        rationale_token: "tok_r",
        appeal_instructions_token: "tok_a"
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
        decision: :deferred,
        rationale_token: "tok_r"
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
