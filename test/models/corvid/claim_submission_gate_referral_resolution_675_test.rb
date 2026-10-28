# frozen_string_literal: true

require "test_helper"

# Issue #675 / PR #693: authorization, fulfilment, and alternate-resource claim
# gates must judge the referral this save will link — not a stale prc_referral_id.
class Corvid::ClaimSubmissionGateReferralResolution675Test < ActiveSupport::TestCase
  TENANT = "tnt_test"
  FACILITY = "fac_test"
  PATIENT = "TEST,PATIENT 001"

  setup do
    Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
  end

  test "submit! refuses when referral_identifier names stale-alternate referral while link still points at current care" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral_a = authorized_referral_with_fulfilment!("rf_gate675_submit_a")
        referral_b = authorized_referral_with_fulfilment!("rf_gate675_submit_b")
        referral_b.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 60.days.ago)

        Corvid.adapter.define_singleton_method(:verify_eligibility) { |_pid, _type| nil }

        claim = linked_claim(referral_a)
        claim.referral_identifier = referral_b.referral_identifier

        adapter = submit_claim_counting_adapter
        assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) { claim.submit! }

        assert_equal 0, adapter.submit_claim_count
        claim.reload
        assert_equal "draft", claim.status
        assert_nil claim.submitted_at
        assert_equal referral_a.id, claim.prc_referral_id
      end
    end
  end

  test "mark_submitted! refuses when referral_identifier names stale-alternate referral while link still points at current care" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral_a = authorized_referral_with_fulfilment!("rf_gate675_mark_a")
        referral_b = authorized_referral_with_fulfilment!("rf_gate675_mark_b")
        referral_b.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 60.days.ago)

        Corvid.adapter.define_singleton_method(:verify_eligibility) { |_pid, _type| nil }

        claim = linked_claim(referral_a)
        claim.referral_identifier = referral_b.referral_identifier

        assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) do
          claim.mark_submitted!(claim_identifier: "CLM-G675-STALE-LINK")
        end

        claim.reload
        assert_equal "draft", claim.status
        assert_nil claim.claim_identifier
        assert_nil claim.submitted_at
        assert_equal referral_a.id, claim.prc_referral_id
      end
    end
  end

  private

  class SubmitClaimCountingAdapter < Corvid::Adapters::MockAdapter
    def initialize
      super()
      @submit_claim_count = 0
    end

    def submit_claim(claim_data)
      @submit_claim_count += 1
      super(claim_data)
    end

    attr_reader :submit_claim_count
  end

  def submit_claim_counting_adapter
    adapter = SubmitClaimCountingAdapter.new
    Corvid.configure { |c| c.adapter = adapter }
    adapter
  end

  def authorized_referral_with_fulfilment!(identifier)
    kase = Corvid::Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
    referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: FACILITY
    )
    Corvid::AlternateResourceCheck.create_all_for_referral(referral)
    exhaust_alternate_resources!(referral)
    referral.update_column(:status, "authorized")
    record_external_report!(referral, outcome: "delivered", reported_at: Time.current)
    referral.reload
  end

  def linked_claim(referral)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier,
      prc_referral: referral,
      referral_identifier: referral.referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 15),
      billed_amount: 100.0,
      status: "draft"
    )
  end

  def record_external_report!(referral, outcome:, reported_at:)
    Corvid::ReferralFulfilment.record_external_report!(
      referral,
      source: "receiving_specialist",
      outcome: outcome,
      reported_at: reported_at
    )
  end
end
