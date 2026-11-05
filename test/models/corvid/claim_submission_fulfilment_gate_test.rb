# frozen_string_literal: true

require "test_helper"

# Claim submission for a linked PRC referral requires an external fulfilment
# report naming delivered care (#675). These tests pin the gate on both adapter
# submission and manual mark_submitted! paths.
class Corvid::ClaimSubmissionFulfilmentGateTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  FACILITY = "fac_test"
  PATIENT = "TEST,PATIENT 001"

  test "submit! refuses a linked authorized referral with no fulfilment report" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_gate_none")
      claim = linked_claim(referral)

      error = assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) { claim.submit! }

      assert_match(/fulfilment|delivered|awaiting_report/i, error.message)
      assert_equal "draft", claim.reload.status
      assert_nil claim.submitted_at
    end
  end

  test "submit! refuses when the latest fulfilment report is not_delivered" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_gate_not_delivered")
      record_external_report!(referral, outcome: "not_delivered", reported_at: Time.current)
      claim = linked_claim(referral)

      assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) { claim.submit! }
      assert_equal "draft", claim.reload.status
    end
  end

  test "submit! refuses when a later not_delivered report supersedes delivered" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_gate_superseded")
      record_external_report!(referral, outcome: "delivered", reported_at: 2.days.ago)
      record_external_report!(referral, outcome: "not_delivered", reported_at: Time.current)
      claim = linked_claim(referral)

      assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) { claim.submit! }
    end
  end

  test "submit! proceeds for a linked referral whose latest report is delivered" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_gate_ok")
      record_external_report!(referral, outcome: "delivered", reported_at: Time.current)
      claim = linked_claim(referral)

      claim.submit!

      assert_equal "submitted", claim.reload.status
      refute_nil claim.submitted_at
    end
  end

  test "mark_submitted! refuses without a delivered fulfilment report" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_mark_none")
      claim = linked_claim(referral)

      assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) do
        claim.mark_submitted!(claim_identifier: "CLM-MANUAL-1")
      end
      assert_equal "draft", claim.reload.status
      assert_nil claim.claim_identifier
    end
  end

  test "mark_submitted! proceeds when delivered care is recorded" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_mark_ok")
      record_external_report!(referral, outcome: "delivered", reported_at: Time.current)
      claim = linked_claim(referral)

      claim.mark_submitted!(claim_identifier: "CLM-MANUAL-2")

      assert_equal "submitted", claim.reload.status
      assert_equal "CLM-MANUAL-2", claim.claim_identifier
    end
  end

  OTHER_PATIENT = "TEST,PATIENT 002"

  test "submit! refuses when referral_identifier names an undelivered referral while prc_referral still points at delivered care" do
    with_tenant(TENANT) do
      delivered = authorized_referral("rf_fulfil_stale_submit_a")
      undelivered = authorized_referral("rf_fulfil_stale_submit_b")
      record_external_report!(delivered, outcome: "delivered", reported_at: Time.current)
      claim = linked_claim(delivered)
      claim.referral_identifier = undelivered.referral_identifier

      adapter = submit_claim_counting_adapter
      error = assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) { claim.submit! }

      assert_match(/#{undelivered.referral_identifier}/, error.message)
      assert_match(/awaiting_report|fulfilment/i, error.message)
      assert_equal 0, adapter.submit_claim_count
      assert_equal "draft", claim.reload.status
      assert_nil claim.submitted_at
      assert_equal delivered.id, claim.prc_referral_id
    end
  end

  test "mark_submitted! refuses when referral_identifier names an undelivered referral while prc_referral still points at delivered care" do
    with_tenant(TENANT) do
      delivered = authorized_referral("rf_fulfil_stale_mark_a")
      undelivered = authorized_referral("rf_fulfil_stale_mark_b")
      record_external_report!(delivered, outcome: "delivered", reported_at: Time.current)
      claim = linked_claim(delivered)
      claim.referral_identifier = undelivered.referral_identifier

      assert_raises(Corvid::ClaimSubmission::FulfilmentNotRecorded) do
        claim.mark_submitted!(claim_identifier: "CLM-STALE-MARK")
      end

      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.claim_identifier
      assert_equal delivered.id, claim.prc_referral_id
    end
  end

  test "mark_submitted! refuses a claim naming another patient's referral like submit!" do
    with_tenant(TENANT) do
      referral = authorized_referral("rf_fulfil_xpat_mark")
      record_external_report!(referral, outcome: "delivered", reported_at: Time.current)
      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: FACILITY,
        patient_identifier: OTHER_PATIENT,
        referral_identifier: referral.referral_identifier,
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 100.0,
        status: "draft"
      )
      assert_nil claim.prc_referral_id

      error = assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) do
        claim.mark_submitted!(claim_identifier: "CLM-XPAT-MARK")
      end

      assert_match(/not this patient's/, error.message)
      assert_equal "draft", claim.reload.status
      assert_nil claim.claim_identifier
    end
  end

  test "mark_submitted! refuses a claim naming an ambiguous referral like submit!" do
    with_tenant(TENANT) do
      ambiguous_identifier = "rf_fulfil_ambig_mark"
      duplicate_authorized_referrals_at(nil, ambiguous_identifier)
      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: nil,
        patient_identifier: PATIENT,
        referral_identifier: ambiguous_identifier,
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 100.0,
        status: "draft"
      )
      assert_nil claim.prc_referral_id

      error = assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) do
        claim.mark_submitted!(claim_identifier: "CLM-AMBIG-MARK")
      end

      assert_match(/several share it|cannot be established/, error.message)
      assert_equal "draft", claim.reload.status
    end
  end

  test "submit! refuses when referral_identifier names another patient's draft referral while prc_referral still points at authorized delivered care" do
    with_tenant(TENANT) do
      delivered = authorized_referral("rf_fulfil_auth_dirty_submit")
      record_external_report!(delivered, outcome: "delivered", reported_at: Time.current)
      claim = linked_claim(delivered)
      other_kase = Corvid::Case.create!(patient_identifier: OTHER_PATIENT, facility_identifier: FACILITY)
      draft = Corvid::PrcReferral.create!(
        case: other_kase,
        referral_identifier: "rf_fulfil_auth_dirty_other",
        facility_identifier: FACILITY
      )
      claim.referral_identifier = draft.referral_identifier

      adapter = submit_claim_counting_adapter
      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }

      assert_equal 0, adapter.submit_claim_count
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier
      assert_equal delivered.id, claim.prc_referral_id
      assert_equal delivered.referral_identifier, claim.referral_identifier
    end
  end

  test "mark_submitted! refuses when referral_identifier names another patient's draft referral while prc_referral still points at authorized delivered care" do
    with_tenant(TENANT) do
      delivered = authorized_referral("rf_fulfil_auth_dirty_mark")
      record_external_report!(delivered, outcome: "delivered", reported_at: Time.current)
      claim = linked_claim(delivered)
      other_kase = Corvid::Case.create!(patient_identifier: OTHER_PATIENT, facility_identifier: FACILITY)
      draft = Corvid::PrcReferral.create!(
        case: other_kase,
        referral_identifier: "rf_fulfil_auth_dirty_mark_other",
        facility_identifier: FACILITY
      )
      claim.referral_identifier = draft.referral_identifier

      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) do
        claim.mark_submitted!(claim_identifier: "CLM-AUTH-DIRTY-MARK")
      end

      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.claim_identifier
      assert_equal delivered.id, claim.prc_referral_id
      assert_equal delivered.referral_identifier, claim.referral_identifier
    end
  end

  test "submit! refuses when referral_identifier names same patient's unauthorized delivered referral while prc_referral still points at authorized care" do
    with_tenant(TENANT) do
      authorized = authorized_referral("rf_fulfil_auth_samept_submit_a")
      record_external_report!(authorized, outcome: "delivered", reported_at: Time.current)
      unauthorized = authorized_referral("rf_fulfil_auth_samept_submit_b")
      record_external_report!(unauthorized, outcome: "delivered", reported_at: Time.current)
      unauthorized.update_column(:status, "priority_assignment")
      claim = linked_claim(authorized)
      claim.referral_identifier = unauthorized.referral_identifier

      adapter = submit_claim_counting_adapter
      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }

      assert_equal 0, adapter.submit_claim_count
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
      assert_equal authorized.id, claim.prc_referral_id
    end
  end

  test "mark_submitted! refuses when referral_identifier names same patient's unauthorized delivered referral while prc_referral still points at authorized care" do
    with_tenant(TENANT) do
      authorized = authorized_referral("rf_fulfil_auth_samept_mark_a")
      record_external_report!(authorized, outcome: "delivered", reported_at: Time.current)
      unauthorized = authorized_referral("rf_fulfil_auth_samept_mark_b")
      record_external_report!(unauthorized, outcome: "delivered", reported_at: Time.current)
      unauthorized.update_column(:status, "priority_assignment")
      claim = linked_claim(authorized)
      claim.referral_identifier = unauthorized.referral_identifier

      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) do
        claim.mark_submitted!(claim_identifier: "CLM-AUTH-SAMEPT-MARK")
      end

      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.claim_identifier
      assert_equal authorized.id, claim.prc_referral_id
    end
  end

  test "submit! without a linked referral is unchanged by the fulfilment gate" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: FACILITY,
        patient_identifier: PATIENT,
        referral_identifier: "EXTERNAL-ONLY-675",
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 100.0,
        status: "draft"
      )
      assert_nil claim.prc_referral_id

      claim.submit!

      assert_equal "submitted", claim.reload.status
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

  def duplicate_authorized_referrals_at(facility_identifier, referral_identifier)
    2.times do |index|
      kase = Corvid::Case.create!(
        patient_identifier: "PAT-AMB-#{index}-#{SecureRandom.hex(2)}",
        facility_identifier: facility_identifier || FACILITY
      )
      referral = Corvid::PrcReferral.new(
        case: kase,
        referral_identifier: referral_identifier,
        facility_identifier: facility_identifier
      )
      referral.save!(validate: false)
      Corvid::AlternateResourceCheck.create_all_for_referral(referral)
      exhaust_alternate_resources!(referral)
      referral.update_column(:status, "authorized")
    end
  end

  def authorized_referral(identifier)
    kase = Corvid::Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
    referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: FACILITY
    )
    Corvid::AlternateResourceCheck.create_all_for_referral(referral)
    exhaust_alternate_resources!(referral)
    referral.update_column(:status, "authorized")
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
      service_date: Date.current,
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
