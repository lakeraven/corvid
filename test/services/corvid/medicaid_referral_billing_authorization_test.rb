# frozen_string_literal: true

require "test_helper"

# Review finding (PR #598, medium): "Require referral authorization before
# fulfilment" — Corvid::MedicaidReferralBilling's own class comment states
# a claim is billable "once both are true" (authorization AND fulfilment),
# but #submit_claim! only checked fulfilment. Because
# ReferralFulfilment.record_external_report! accepts any referral
# regardless of AASM state, an unauthorized (e.g. still-draft) referral
# that happened to receive a "delivered" report could be billed.
class Corvid::MedicaidReferralBillingAuthorizationTest < ActiveSupport::TestCase
  TENANT = "tnt_billing_authorization"

  test "submit_claim! rejects an unauthorized referral even when fulfilment recorded delivered care" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_unauth", facility_identifier: "fac_unauth")
      referral = Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_unauth", facility_identifier: "fac_unauth")
      refute referral.authorized?, "Precondition: referral is still in draft, not authorized"

      Corvid::ReferralFulfilment.record_external_report!(
        referral, source: "receiving_specialist", outcome: "delivered", reported_at: Time.current
      )

      error = assert_raises(Corvid::MedicaidReferralBilling::SubmissionRejected) do
        Corvid::MedicaidReferralBilling.submit_claim!(
          referral: referral, cpt_code: "99243", charge: 100.0, provider_identifier: "pr_x"
        )
      end
      assert_includes error.message, "authoriz"
    end
  end

  test "submit_claim! proceeds once the referral is authorized and fulfilment recorded delivered care" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_auth", facility_identifier: "fac_unauth")
      referral = Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_auth", facility_identifier: "fac_unauth")
      Corvid::MedicaidReferralWorkflow.bootstrap_authorized_medicaid_referral!(referral)
      assert referral.reload.authorized?

      Corvid::ReferralFulfilment.record_external_report!(
        referral, source: "receiving_specialist", outcome: "delivered", reported_at: Time.current
      )

      claim = Corvid::MedicaidReferralBilling.submit_claim!(
        referral: referral, cpt_code: "99243", charge: 100.0, provider_identifier: "pr_x"
      )
      assert_equal referral.id, claim.prc_referral_id
    end
  end
end
