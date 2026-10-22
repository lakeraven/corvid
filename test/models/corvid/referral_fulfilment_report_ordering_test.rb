# frozen_string_literal: true

require "test_helper"

# Review finding (PR #598, medium): "Add stable ordering for equal report
# timestamps" — #latest_report depended on reverse_chronological, which
# ordered only by reported_at. Two reports sharing one reported_at value
# had no defined winner; Postgres may return either row first, making
# fulfilment (and therefore billability) nondeterministic. The later
# APPENDED report (highest id) must always win a tie.
class Corvid::ReferralFulfilmentReportOrderingTest < ActiveSupport::TestCase
  TENANT = "tnt_fulfilment_ordering"

  test "the later-inserted report wins when reported_at is identical" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_order", facility_identifier: "fac_order")
      referral = Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_order", facility_identifier: "fac_order")
      same_time = Time.zone.parse("2026-03-15T16:00:00Z")

      Corvid::ReferralFulfilment.record_external_report!(
        referral, source: "patient", outcome: "not_delivered", reported_at: same_time
      )
      second = Corvid::ReferralFulfilment.record_external_report!(
        referral, source: "receiving_specialist", outcome: "delivered", reported_at: same_time
      )

      assert_equal second.id, Corvid::ReferralFulfilment.latest_report(referral).id
      assert_equal "delivered", Corvid::ReferralFulfilment.status(referral)
    end
  end

  test "chronological and reverse_chronological are exact reverses of each other on a tie" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_order_2", facility_identifier: "fac_order")
      referral = Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_order_2", facility_identifier: "fac_order")
      same_time = Time.zone.parse("2026-03-15T16:00:00Z")

      first = Corvid::ReferralFulfilmentReport.create!(
        tenant_identifier: TENANT, facility_identifier: "fac_order", prc_referral: referral,
        source: "patient", outcome: "not_delivered", reported_at: same_time
      )
      second = Corvid::ReferralFulfilmentReport.create!(
        tenant_identifier: TENANT, facility_identifier: "fac_order", prc_referral: referral,
        source: "receiving_specialist", outcome: "delivered", reported_at: same_time
      )

      assert_equal [ first.id, second.id ], referral.fulfilment_reports.chronological.pluck(:id)
      assert_equal [ second.id, first.id ], referral.fulfilment_reports.reverse_chronological.pluck(:id)
    end
  end
end
