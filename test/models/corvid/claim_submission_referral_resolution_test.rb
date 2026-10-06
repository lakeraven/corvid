# frozen_string_literal: true

require "test_helper"

# Review finding (PR #598, high): "Include facility identifier in referral
# lookup" — PrcReferral.referral_identifier is only unique scoped to
# [tenant_identifier, facility_identifier] (app/models/corvid/prc_referral.rb),
# so a claim's best-effort backfill must match on all three, not
# referral_identifier alone, or it can silently attach to the wrong
# facility's referral (and therefore the wrong patient's care record).
class Corvid::ClaimSubmissionReferralResolutionTest < ActiveSupport::TestCase
  TENANT = "tnt_cs_referral_resolution"

  test "resolves the referral at the claim's own facility, not a same-tenant same-identifier referral elsewhere" do
    with_tenant(TENANT) do
      kase_a = Corvid::Case.create!(patient_identifier: "pt_res_a", facility_identifier: "fac_a")
      kase_b = Corvid::Case.create!(patient_identifier: "pt_res_b", facility_identifier: "fac_b")

      referral_a = Corvid::PrcReferral.create!(case: kase_a, referral_identifier: "rf_shared", facility_identifier: "fac_a")
      referral_b = Corvid::PrcReferral.create!(case: kase_b, referral_identifier: "rf_shared", facility_identifier: "fac_b")

      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT, facility_identifier: "fac_b",
        patient_identifier: "pt_res_b", referral_identifier: "rf_shared",
        claim_type: "professional", service_date: Date.current, billed_amount: 100.0
      )

      assert_equal referral_b.id, claim.prc_referral_id
      refute_equal referral_a.id, claim.prc_referral_id
    end
  end

  test "does not resolve a referral at a different facility when no same-facility match exists" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_res_c", facility_identifier: "fac_other")
      Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_only_elsewhere", facility_identifier: "fac_other")

      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT, facility_identifier: "fac_c",
        patient_identifier: "pt_res_d", referral_identifier: "rf_only_elsewhere",
        claim_type: "professional", service_date: Date.current, billed_amount: 100.0
      )

      assert_nil claim.prc_referral_id
    end
  end
end
