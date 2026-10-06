# frozen_string_literal: true

require "test_helper"

# Review finding (PR #598, high): "Prevent deletion of fulfilment history" —
# Corvid::ReferralFulfilment.clear_reports! was a public production method
# that destroyed a referral's entire reporting history, contradicting the
# append-only audit guarantee documented on both this service and
# Corvid::ReferralFulfilmentReport. The only legitimate caller was test
# arrangement (features/step_definitions/medicaid_referral_steps.rb), which
# now destroys reports directly as test setup instead of through a
# production API. This pins the absence of that API.
class Corvid::ReferralFulfilmentAppendOnlyTest < ActiveSupport::TestCase
  TENANT = "tnt_fulfilment_append_only"

  test "ReferralFulfilment exposes no production method that deletes reports" do
    refute Corvid::ReferralFulfilment.respond_to?(:clear_reports!),
      "Corvid::ReferralFulfilment must not expose a way to erase fulfilment history"
  end

  test "recording a second report never removes the first" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_append_only", facility_identifier: "fac_append_only")
      referral = Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_append_only", facility_identifier: "fac_append_only")

      Corvid::ReferralFulfilment.record_external_report!(
        referral, source: "patient", outcome: "not_delivered", reported_at: 1.day.ago
      )
      Corvid::ReferralFulfilment.record_external_report!(
        referral, source: "receiving_specialist", outcome: "delivered", reported_at: Time.current
      )

      assert_equal 2, referral.fulfilment_reports.count,
        "Both reports must remain on file; the most recent one changes status, not history"
      assert_equal "delivered", Corvid::ReferralFulfilment.status(referral)
    end
  end
end
