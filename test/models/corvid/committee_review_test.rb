# frozen_string_literal: true

require "test_helper"

class Corvid::CommitteeReviewTest < ActiveSupport::TestCase
  TENANT = "tnt_cr_test"

  setup do
    Corvid::CommitteeReview.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # -- Creation ---------------------------------------------------------------

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

  # -- Decision transitions ---------------------------------------------------

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
      review.update!(decision: :denied, rationale_token: "rt_test", appeal_instructions_token: "ai_test")
      assert review.denied?
    end
  end

  test "can defer" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :deferred, rationale_token: "rt_test")
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

  # -- Predicates -------------------------------------------------------------

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

  # -- Scopes -----------------------------------------------------------------

  test "upcoming returns pending reviews with future date" do
    with_tenant(TENANT) do
      upcoming = create_review(committee_date: 1.week.from_now)
      past = create_review(committee_date: 1.week.ago)

      assert_includes Corvid::CommitteeReview.upcoming, upcoming
      refute_includes Corvid::CommitteeReview.upcoming, past
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

  # -- Validations -----------------------------------------------------------

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

  # -- Decision enum ---------------------------------------------------------

  test "decision enum includes expected values" do
    with_tenant(TENANT) do
      expected_keys = %w[pending approved denied deferred modified]
      assert_equal expected_keys.sort, Corvid::CommitteeReview.decisions.keys.sort
    end
  end

  # -- Scopes ----------------------------------------------------------------

  test "chronological scope orders by committee_date asc" do
    with_tenant(TENANT) do
      r1 = create_review(committee_date: 3.days.ago)
      r2 = create_review(committee_date: 1.day.ago)
      r3 = create_review(committee_date: 2.days.ago)

      ordered = Corvid::CommitteeReview.chronological.to_a
      assert_equal [r1, r3, r2], ordered
    end
  end

  test "reverse_chronological scope orders by committee_date desc" do
    with_tenant(TENANT) do
      r1 = create_review(committee_date: 3.days.ago)
      r2 = create_review(committee_date: 1.day.ago)

      ordered = Corvid::CommitteeReview.reverse_chronological
      assert_equal r2, ordered.first
    end
  end

  test "for_date scope filters by date" do
    with_tenant(TENANT) do
      today = create_review(committee_date: Date.current)
      yesterday = create_review(committee_date: Date.current - 1.day)

      results = Corvid::CommitteeReview.for_date(Date.current)
      assert_includes results, today
      refute_includes results, yesterday
    end
  end

  test "decided scope excludes pending" do
    with_tenant(TENANT) do
      pending_r = create_review
      approved_r = create_review_with_decision(:approved, approved_amount: 50_000)

      decided = Corvid::CommitteeReview.decided
      assert_includes decided, approved_r
      refute_includes decided, pending_r
    end
  end

  test "pending_decision scope returns only pending" do
    with_tenant(TENANT) do
      pending_r = create_review
      approved_r = create_review_with_decision(:approved, approved_amount: 50_000)

      pending_reviews = Corvid::CommitteeReview.pending_decision
      assert_includes pending_reviews, pending_r
      refute_includes pending_reviews, approved_r
    end
  end

  # -- Class methods ---------------------------------------------------------

  test "upcoming_reviews returns reviews in next N days" do
    with_tenant(TENANT) do
      tomorrow = create_review(committee_date: Date.current + 1.day)
      next_week = create_review(committee_date: Date.current + 5.days)
      far_future = create_review(committee_date: Date.current + 10.days)

      upcoming = Corvid::CommitteeReview.upcoming_reviews(days: 7)

      assert_includes upcoming, tomorrow
      assert_includes upcoming, next_week
      refute_includes upcoming, far_future
    end
  end

  test "requires_committee_review? returns true for high-cost referrals" do
    with_tenant(TENANT) do
      referral = create_referral
      referral.update!(estimated_cost: 60_000)
      assert Corvid::CommitteeReview.requires_committee_review?(referral)
    end
  end

  test "requires_committee_review? returns false for low-cost referrals" do
    with_tenant(TENANT) do
      referral = create_referral
      referral.update!(estimated_cost: 10_000)
      refute Corvid::CommitteeReview.requires_committee_review?(referral)
    end
  end

  test "requires_committee_review? returns true for priority 3 or higher" do
    with_tenant(TENANT) do
      referral = create_referral
      referral.update!(estimated_cost: 1_000, medical_priority: 3)
      assert Corvid::CommitteeReview.requires_committee_review?(referral)
    end
  end

  test "requires_committee_review? returns true when flagged_for_review" do
    with_tenant(TENANT) do
      referral = create_referral
      referral.update!(estimated_cost: 1_000, flagged_for_review: true)
      assert Corvid::CommitteeReview.requires_committee_review?(referral)
    end
  end

  # -- Instance methods ------------------------------------------------------

  test "finalized? returns true for denied" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :denied, rationale_token: "rt_test", appeal_instructions_token: "ai_test")
      assert review.finalized?
    end
  end

  test "approved_or_modified? returns true for approved" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :approved)
      assert review.approved_or_modified?
    end
  end

  test "approved_or_modified? returns true for modified" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :modified)
      assert review.approved_or_modified?
    end
  end

  test "approved_or_modified? returns false for denied" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :denied)
      refute review.approved_or_modified?
    end
  end

  test "requires_followup? returns true for deferred" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :deferred)
      assert review.requires_followup?
    end
  end

  test "requires_followup? returns true for modified" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :modified)
      assert review.requires_followup?
    end
  end

  test "requires_followup? returns false for approved" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :approved)
      refute review.requires_followup?
    end
  end

  # -- Decision summary ------------------------------------------------------

  test "decision_summary for pending" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :pending)
      assert_equal "Pending committee review", review.decision_summary
    end
  end

  test "decision_summary for approved" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :approved, approved_amount: 50_000)
      summary = review.decision_summary
      assert_includes summary, "Approved"
      assert_includes summary, "50000"
    end
  end

  test "decision_summary for denied" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :denied)
      assert_equal "Denied", review.decision_summary
    end
  end

  test "decision_summary for deferred" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :deferred, rationale_token: "rt_test")
      assert_includes review.decision_summary, "Deferred"
    end
  end

  test "decision_summary for modified" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(decision: :modified, approved_amount: 40_000)
      assert_includes review.decision_summary, "Approved with modifications"
    end
  end

  # -- Callbacks -------------------------------------------------------------

  test "sets appeal_deadline when denied" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.create!(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :denied,
        rationale_token: "rt_test",
        appeal_instructions_token: "ai_test"
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
        rationale_token: "rt_test",
        appeal_instructions_token: "ai_test",
        appeal_deadline: custom
      )
      assert_equal custom, review.appeal_deadline
    end
  end

  # -- Stored amounts --------------------------------------------------------

  test "stores requested_amount" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.create!(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :modified,
        rationale_token: "rt_test",
        requested_amount: 100_000,
        approved_amount: 75_000
      )
      review.reload
      assert_equal 100_000, review.requested_amount.to_i
      assert_equal 75_000, review.approved_amount.to_i
    end
  end

  # -- apply_to_referral! ---------------------------------------------------

  test "apply_to_referral! does nothing when pending" do
    with_tenant(TENANT) do
      referral = create_referral
      original_status = referral.status
      review = create_review(committee_date: Date.current)
      review.apply_to_referral!
      referral.reload
      assert_equal original_status, referral.status
    end
  end

  # -- upcoming_reviews excludes decided -------------------------------------

  test "upcoming_reviews excludes decided reviews" do
    with_tenant(TENANT) do
      upcoming_pending = create_review(committee_date: Date.current + 1.day)
      upcoming_approved = create_review(committee_date: Date.current + 1.day)
      upcoming_approved.update_column(:decision, "approved")
      upcoming_approved.update_column(:approved_amount, 50_000)

      upcoming = Corvid::CommitteeReview.upcoming_reviews(days: 7)

      assert_includes upcoming, upcoming_pending
      refute_includes upcoming, upcoming_approved
    end
  end

  # -- Additional validations ------------------------------------------------

  test "requires appeal_instructions_token when denied" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.new(
        prc_referral: create_referral,
        committee_date: Date.current,
        decision: :denied,
        rationale_token: "rt_test",
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
        rationale_token: "rt_test",
        appeal_instructions_token: "ai_test"
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

  # -- Summary ---------------------------------------------------------------

  test "summary includes key information" do
    with_tenant(TENANT) do
      review = create_review(committee_date: Date.current)
      review.update_column(:decision, "approved")
      review.update_column(:approved_amount, 50_000)

      summary = review.summary

      assert_includes summary, "Committee Review"
      assert_includes summary, "Approved"
    end
  end

  # -- finalized? for deferred ------------------------------------------------

  test "finalized? returns true for deferred" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :deferred, rationale_token: "rt_test")
      assert review.finalized?
    end
  end

  test "finalized? returns true for modified" do
    with_tenant(TENANT) do
      review = create_review
      review.update!(decision: :modified, approved_amount: 40_000)
      assert review.finalized?
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

  def create_referral
    Corvid::PrcReferral.create!(
      case: create_case,
      referral_identifier: "ref_#{SecureRandom.hex(4)}"
    )
  end

  def create_review(committee_date: Date.current, **attrs)
    Corvid::CommitteeReview.create!(
      prc_referral: attrs.delete(:prc_referral) || create_referral,
      committee_date: committee_date,
      **attrs
    )
  end

  def create_review_with_decision(decision, **attrs)
    review = create_review
    review.update_column(:decision, decision.to_s)
    attrs.each { |k, v| review.update_column(k, v) }
    review
  end
end
