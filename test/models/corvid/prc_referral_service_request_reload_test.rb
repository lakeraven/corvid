# frozen_string_literal: true

require "test_helper"

# Issue #675 / PR #693: reload must drop memoized EHR service_request so
# committee routing sees current adapter data.
module Corvid
  class PrcReferralServiceRequestReloadTest < ActiveSupport::TestCase
    TENANT = "tnt_g693_stale_sr"
    FACILITY = "fac_g693"
    PATIENT = "TEST,PATIENT STALE"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    test "reload clears memoized service_request so requires_committee? reflects updated EHR priority" do
      with_tenant(TENANT) do
        kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
        referral = PrcReferral.create!(
          case: kase,
          referral_identifier: "rf_g693_stale",
          facility_identifier: FACILITY,
          estimated_cost: 100,
          medical_priority: 2,
          flagged_for_review: false
        )
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: 100,
          medical_priority_level: 2,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )

        assert_equal 2, referral.service_request.medical_priority_level
        refute referral.requires_committee?

        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: 100,
          medical_priority_level: 4,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload

        assert_equal 4, Corvid.adapter.find_referral(referral.referral_identifier).medical_priority_level
        assert referral.requires_committee?,
          "after reload, requires_committee? must read fresh EHR medical_priority_level"
      end
    end
  end
end
