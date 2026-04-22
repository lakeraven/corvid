# frozen_string_literal: true

require "test_helper"

class Corvid::CommitteeReviewSyncServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_crs_test"

  setup do
    Corvid::CommitteeReview.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  test "finalized review can apply to referral" do
    with_tenant(TENANT) do
      referral = create_referral
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral, committee_date: Date.current, decision: "approved"
      )

      assert review.finalized?
    end
  end

  test "pending review is not finalized" do
    with_tenant(TENANT) do
      referral = create_referral
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral, committee_date: Date.current
      )

      refute review.finalized?
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_crs", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end
end
