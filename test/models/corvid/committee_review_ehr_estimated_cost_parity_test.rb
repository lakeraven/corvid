# frozen_string_literal: true

require "test_helper"

# Issue #675 / PR #693: CommitteeReview.requires_committee_review? must use the
# same effective cost as PrcReferral#requires_committee? (including EHR).
module Corvid
  class CommitteeReviewEhrEstimatedCostParityTest < ActiveSupport::TestCase
    TENANT = "tnt_g693_ehr_cost"
    FACILITY = "fac_g693"
    PATIENT = "TEST,PATIENT G693"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    test "requires_committee_review? agrees with PrcReferral when cost is only on the EHR" do
      with_tenant(TENANT) do
        kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
        referral = PrcReferral.create!(
          case: kase,
          referral_identifier: "rf_g693_ehr_cost",
          facility_identifier: FACILITY,
          estimated_cost: nil,
          medical_priority: 2,
          flagged_for_review: false
        )
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: 60_000,
          medical_priority_level: 2,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload

        assert referral.requires_committee?, "PrcReferral must see EHR estimated_cost"
        assert CommitteeReview.requires_committee_review?(referral),
          "CommitteeReview must match PrcReferral when EHR cost is at or above threshold"
        assert_equal referral.requires_committee?, CommitteeReview.requires_committee_review?(referral)
      end
    end
  end
end
