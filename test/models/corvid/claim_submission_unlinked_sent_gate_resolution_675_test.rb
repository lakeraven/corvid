# frozen_string_literal: true

require "test_helper"

# Issue #675 / PR #693: submission gates must resolve an unambiguous same-patient
# referral for already-sent unlinked claims (without a plain save), link on
# submit! / mark_submitted!, and refuse with the true authorization reason.
class Corvid::ClaimSubmissionUnlinkedSentGateResolution675Test < ActiveSupport::TestCase
  TENANT = "tnt_g675_unlinked_gate"
  FACILITY = "fac_g675_unlinked_gate"
  PATIENT = "TEST,PATIENT G675 UNLINKED GATE"

  setup do
    Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
  end

  test "submit! on error row with submitted_at links authorized referral after care is recorded" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        identifier = "rf_g675_err_resubmit"
        claim = unlinked_sent_error_with_submitted_at!(identifier)
        referral = authorized_referral_with_fulfilment!(identifier)
        stub_submission_adapter!("CLM-G675-ERR-RESUB")

        assert_nothing_raised { claim.submit! }

        claim.reload
        assert_equal referral.id, claim.prc_referral_id
        assert_equal "submitted", claim.status
        assert_equal "CLM-G675-ERR-RESUB", claim.claim_identifier
      end
    end
  end

  test "submit! on rejected row with claim_identifier links authorized referral after care is recorded" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        identifier = "rf_g675_rej_resubmit"
        claim = unlinked_sent_rejected_with_claim_id!(identifier)
        referral = authorized_referral_with_fulfilment!(identifier)
        stub_submission_adapter!("CLM-G675-REJ-RESUB")

        assert_nothing_raised { claim.submit! }

        claim.reload
        assert_equal referral.id, claim.prc_referral_id
        assert_equal "submitted", claim.status
      end
    end
  end

  test "mark_submitted! on error row with submitted_at links authorized referral" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        identifier = "rf_g675_err_mark"
        claim = unlinked_sent_error_with_submitted_at!(identifier)
        referral = authorized_referral_with_fulfilment!(identifier)

        assert_nothing_raised do
          claim.mark_submitted!(claim_identifier: "CLM-G675-ERR-MARK")
        end

        claim.reload
        assert_equal referral.id, claim.prc_referral_id
        assert_equal "submitted", claim.status
        assert_equal "CLM-G675-ERR-MARK", claim.claim_identifier
      end
    end
  end

  test "mark_submitted! on rejected row with claim_identifier links authorized referral" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        identifier = "rf_g675_rej_mark"
        claim = unlinked_sent_rejected_with_claim_id!(identifier)
        referral = authorized_referral_with_fulfilment!(identifier)

        assert_nothing_raised do
          claim.mark_submitted!(claim_identifier: "CLM-G675-REJ-MARK")
        end

        claim.reload
        assert_equal referral.id, claim.prc_referral_id
        assert_equal "submitted", claim.status
      end
    end
  end

  test "submit! on sent unlinked claim refuses unauthorized referral with true reason not ambiguity" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        identifier = "rf_g675_unauth"
        claim = unlinked_sent_error_with_submitted_at!(identifier)
        referral = draft_referral_for!(identifier)
        assert_equal "draft", referral.status

        error = assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }

        assert_match(/not authorized/i, error.message)
        refute_match(/several share it/i, error.message)
        assert_nil claim.reload.prc_referral_id
      end
    end
  end

  test "plain save on sent unlinked claim still does not attach referral per 689" do
    with_tenant(TENANT) do
      identifier = "rf_g675_plain_pin"
      claim = unlinked_sent_error_with_submitted_at!(identifier)
      authorized_referral_with_fulfilment!(identifier)

      assert_nothing_raised { claim.update!(billed_amount: 101.0) }

      claim.reload
      assert_equal 101.0, claim.billed_amount.to_f
      assert_nil claim.prc_referral_id
    end
  end

  private

  def draft_referral_for!(identifier)
    kase = Corvid::Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: FACILITY
    )
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

  def unlinked_claim_shell!(referral_identifier)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: FACILITY,
      patient_identifier: PATIENT,
      referral_identifier: referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 15),
      billed_amount: 100.0,
      status: "draft"
    )
  end

  def unlinked_sent_error_with_submitted_at!(referral_identifier)
    claim = unlinked_claim_shell!(referral_identifier)
    claim.update_columns(
      status: "error",
      submitted_at: Time.zone.parse("2025-06-20 09:00:00 UTC")
    )
    claim.reload
    assert_nil claim.prc_referral_id
    assert claim.submitted_at.present?
    assert_nil claim.claim_identifier
    claim
  end

  def unlinked_sent_rejected_with_claim_id!(referral_identifier)
    claim = unlinked_claim_shell!(referral_identifier)
    Corvid.adapter.define_singleton_method(:submit_claim) do |_|
      { claim_identifier: "CLM-G675-REJ-PRIOR", status: "accepted" }
    end
    claim.submit!
    claim.mark_rejected!(reason_token: "tok_g675_rej")
    claim.reload
    assert_nil claim.prc_referral_id
    assert_equal "rejected", claim.status
    assert_equal "CLM-G675-REJ-PRIOR", claim.claim_identifier
    claim
  end

  def stub_submission_adapter!(claim_identifier)
    Corvid.adapter.define_singleton_method(:verify_eligibility) { |_pid, _type| nil }
    Corvid.adapter.define_singleton_method(:submit_claim) do |_|
      { claim_identifier: claim_identifier, status: "accepted" }
    end
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
