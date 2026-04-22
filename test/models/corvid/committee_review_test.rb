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

  # -- Predicates -------------------------------------------------------------

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
      approved_review.approved!

      refute_includes Corvid::CommitteeReview.finalized, pending_review
      assert_includes Corvid::CommitteeReview.finalized, approved_review
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
      prc_referral: create_referral,
      committee_date: committee_date,
      **attrs
    )
  end
end
