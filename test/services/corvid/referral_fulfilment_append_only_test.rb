# frozen_string_literal: true

require "test_helper"

# The fulfilment trail is the record of whether care actually happened, so it
# is append-only: a correction is a new report, and the derived status reads
# the most recent one. These tests pin that guarantee against the three ways
# ordinary ActiveRecord would otherwise break it — update, destroy, and an
# association cascade from the referral or its case — and against a service
# API that erases history.
class Corvid::ReferralFulfilmentAppendOnlyTest < ActiveSupport::TestCase
  TENANT = "tnt_fulfilment_append_only"

  # Asserting the absence of one named method does not make a trail
  # append-only: ordinary ActiveRecord still offers update, destroy, and
  # association cascade. Each of those is pinned below, and each fails if its
  # guard is removed.
  test "ReferralFulfilment exposes no production method that deletes reports" do
    refute Corvid::ReferralFulfilment.respond_to?(:clear_reports!),
      "Corvid::ReferralFulfilment must not expose a way to erase fulfilment history"
  end

  test "a recorded report cannot be destroyed" do
    with_tenant(TENANT) do
      report = recorded_report("rf_no_destroy")

      assert_raises(ActiveRecord::RecordNotDestroyed) { report.destroy! }
      assert Corvid::ReferralFulfilmentReport.exists?(report.id),
        "the report must survive a destroy attempt"
    end
  end

  test "a recorded report cannot be rewritten" do
    with_tenant(TENANT) do
      report = recorded_report("rf_no_update")

      assert_raises(ActiveRecord::RecordNotSaved) { report.update!(outcome: "not_delivered") }
      assert_equal "delivered", report.reload.outcome,
        "a correction is a new report, never an edit to the original"
    end
  end

  test "destroying the referral does not erase its reports" do
    with_tenant(TENANT) do
      report = recorded_report("rf_no_cascade")
      referral = report.prc_referral

      refute referral.destroy,
        "a referral holding fulfilment reports must refuse to be destroyed"
      assert Corvid::ReferralFulfilmentReport.exists?(report.id),
        "the trail must outlive an attempt to destroy the referral"
    end
  end

  test "destroying the case does not erase fulfilment reports" do
    with_tenant(TENANT) do
      report = recorded_report("rf_no_case_cascade")
      kase = report.prc_referral.case

      assert_raises(ActiveRecord::RecordNotDestroyed) { kase.destroy! }
      assert Corvid::ReferralFulfilmentReport.exists?(report.id),
        "a cascade from the case must not reach the append-only trail"
    end
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

  private

  def recorded_report(referral_id)
    kase = Corvid::Case.create!(patient_identifier: "pt_#{referral_id}", facility_identifier: "fac_append_only")
    referral = Corvid::PrcReferral.create!(
      case: kase, referral_identifier: referral_id, facility_identifier: "fac_append_only"
    )
    Corvid::ReferralFulfilment.record_external_report!(
      referral, source: "receiving_specialist", outcome: "delivered", reported_at: Time.current
    )
    referral.fulfilment_reports.reload.first
  end
end
