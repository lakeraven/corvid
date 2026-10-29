# frozen_string_literal: true

require "test_helper"

# Failing specs for round-1 claim submission gates (#639 / PR #688):
# phase-B alternate-resource re-check, mark_submitted! reconciliation, exception naming.
class Corvid::ClaimSubmissionGateRound1Test < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  TENANT = "tnt_test"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup { travel_to RETRO_SCENARIO_TIME }

  teardown do
    travel_back
    restore_submit_in_flight_claim!
    restore_submit_without_override!
    Corvid::TenantContext.reset!
    truncate_corvid_claim_graph!
  end

  # --- F1: alternate-resource re-check under lock before adapter ----------------

  test "phase B aborts with AlternateResourcesNotCurrent when own referral medicare_a enrolls in gap" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_submit_claim!
      hook_phase_b_gap!(claim.id) { enroll_medicare_a_on_own_referral!(claim.id) }

      assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) { claim.submit! }

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      refute submission_outcome_unknown_row?(row)
    end
  end

  test "no-override submit raises AlternateResourcesNotCurrent when own referral medicare_a enrolls after prepare and before lock" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      submit_calls = stub_submit_claim!
      hook_no_override_pre_lock_gap!(claim.id) { enroll_medicare_a_on_own_referral!(claim.id) }

      assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) { claim.submit! }

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_equal "draft", row.status
      assert_nil row.claim_identifier
      refute submission_outcome_unknown_row?(row)
      assert_nil row.medicaid_hold_override_reason_token
    end
  end

  # --- F2: mark_submitted! reconciliation while outcome unknown -------------------

  test "mark_submitted! while outcome unknown succeeds after own referral medicare_a enrolls" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      enroll_medicare_a_on_own_referral!(claim.id)
      identifier = "CLM-RECON-ARC-#{SecureRandom.hex(3)}"

      claim.mark_submitted!(claim_identifier: identifier)

      row = fresh_claim_row(claim.id)
      refute submission_outcome_unknown_row?(row)
      assert_equal identifier, row.claim_identifier
      assert_equal "submitted", row.status
      assert row.submitted_at.present?
    end
  end

  test "mark_submitted! while outcome unknown succeeds after own referral is no longer authorized" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      deauthorize_claim_own_referral!(claim.id)
      identifier = "CLM-RECON-AUTH-#{SecureRandom.hex(3)}"

      claim.mark_submitted!(claim_identifier: identifier)

      row = fresh_claim_row(claim.id)
      refute submission_outcome_unknown_row?(row)
      assert_equal identifier, row.claim_identifier
      assert_equal "submitted", row.status
    end
  end

  test "mark_submitted! on draft with non-exhausted own referral raises AlternateResourcesNotCurrent" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      enroll_medicare_a_on_own_referral!(claim.id)

      assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) do
        claim.mark_submitted!(claim_identifier: "CLM-DRAFT-ARC-#{SecureRandom.hex(3)}")
      end

      row = fresh_claim_row(claim.id)
      assert_equal "draft", row.status
      assert_nil row.claim_identifier
    end
  end

  test "mark_submitted! on draft with unauthorized own referral raises ReferralNotAuthorized" do
    with_tenant(TENANT) do
      referral = referral_at("fac_test", "REF-MARK-UNAUTH-#{SecureRandom.hex(3)}")
      exhaust_alternate_resources!(referral)
      claim = build_claim_for(referral).tap(&:save!)

      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) do
        claim.mark_submitted!(claim_identifier: "CLM-DRAFT-AUTH-#{SecureRandom.hex(3)}")
      end

      assert_equal "draft", fresh_claim_row(claim.id).status
    end
  end

  # --- F3: exception classes report real Module names ----------------------------

  test "SubmissionOutcomeUnknown reports full Ruby class name" do
    assert_equal(
      "Corvid::ClaimSubmission::SubmissionOutcomeUnknown",
      Corvid::ClaimSubmission::SubmissionOutcomeUnknown.name
    )
  end

  test "InFlightSubmissionChanged reports full Ruby class name" do
    assert_equal(
      "Corvid::ClaimSubmission::InFlightSubmissionChanged",
      Corvid::ClaimSubmission::InFlightSubmissionChanged.name
    )
  end

  private

  @submit_in_flight_original = nil
  @submit_without_override_original = nil

  class << self
    attr_accessor :submit_in_flight_original, :submit_without_override_original
  end

  def hook_phase_b_gap!(claim_id, &block)
    install_submit_in_flight_hook!(claim_id, &block)
  end

  def install_submit_in_flight_hook!(claim_id)
    gap_done = false
    original = submit_in_flight_original_method
    Corvid::ClaimSubmission.define_method(:submit_in_flight_claim!) do |*args, **kwargs, &blk|
      unless gap_done
        gap_done = true
        yield claim_id
      end
      original.bind_call(self, *args, **kwargs, &blk)
    end
  end

  def hook_no_override_pre_lock_gap!(claim_id)
    gap_done = false
    original = self.class.submit_without_override_original ||=
      Corvid::ClaimSubmission.instance_method(:submit_without_override!)
    Corvid::ClaimSubmission.define_method(:submit_without_override!) do
      unless gap_done
        gap_done = true
        yield claim_id
      end
      original.bind_call(self)
    end
  end

  def submit_in_flight_original_method
    self.class.submit_in_flight_original ||=
      Corvid::ClaimSubmission.instance_method(:submit_in_flight_claim!)
  end

  def restore_submit_in_flight_claim!
    original = self.class.submit_in_flight_original
    return unless original

    Corvid::ClaimSubmission.define_method(:submit_in_flight_claim!, original)
  end

  def restore_submit_without_override!
    original = self.class.submit_without_override_original
    return unless original

    Corvid::ClaimSubmission.define_method(:submit_without_override!, original)
  end

  def enroll_medicare_a_on_own_referral!(claim_id)
    peer = Corvid::ClaimSubmission.find(claim_id)
    peer.send(:resolve_prc_referral_from_identifier) if peer.prc_referral.blank? && peer.referral_identifier.present?
    referral = peer.prc_referral
    raise "precondition: claim must bill an own PRC referral" if referral.nil?

    check = referral.alternate_resource_checks.find_by!(resource_type: "medicare_a")
    check.update!(status: "enrolled")
    stamp_alternate_resource_check_current!(
      check,
      date_of_service: peer.service_date,
      as_of: Time.current
    )
  end

  def deauthorize_claim_own_referral!(claim_id)
    peer = Corvid::ClaimSubmission.find(claim_id)
    peer.send(:resolve_prc_referral_from_identifier) if peer.prc_referral.blank? && peer.referral_identifier.present?
    referral = peer.prc_referral
    raise "precondition: claim must bill an own PRC referral" if referral.nil?

    referral.update_columns(status: "eligibility_review")
  end

  def claim_in_outcome_unknown_state!
    claim = held_draft_with_override!
    Corvid.adapter.define_singleton_method(:submit_claim) { |_data| raise StandardError, "send failed" }
    assert_raises(StandardError) { claim.submit! }
    fresh_claim_row(claim.id).tap { |row| assert submission_outcome_unknown_row?(row) }
    Corvid::ClaimSubmission.find(claim.id)
  end

  def held_draft_with_override!
    claim = held_draft_claim!
    claim.override_medicaid_hold!(
      reason_token: "rt_medicaid_hold_override",
      by_identifier: "usr_billing_spec"
    )
    claim.reload
  end

  def held_draft_claim!
    referral = referral_at("fac_test", "REF-GATE-R1-#{SecureRandom.hex(3)}")
    authorize!(referral)
    service_date = Date.new(2027, 2, 1)
    exhaust_alternate_resources!(referral, date_of_service: service_date, as_of: Time.current)
    referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
    seed_patient_pending_medicaid_on_referral!(
      patient_id: referral.case.patient_identifier,
      referral_id: "REF-PEND-#{SecureRandom.hex(3)}",
      application_date: Date.new(2027, 3, 15),
      application_date_source: "staff_entry",
      medicaid_state_code: "XA",
      eligibility_group: "expansion_adult"
    )
    build_claim_for(referral, service_date: service_date).tap(&:save!)
  end

  def clear_to_submit_draft_claim!
    referral = referral_at("fac_test", "REF-GATE-CLEAR-#{SecureRandom.hex(3)}")
    authorize!(referral)
    referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
    build_claim_for(referral, service_date: Date.new(2027, 2, 1)).tap(&:save!)
  end

  def seed_patient_pending_medicaid_on_referral!(patient_id:, referral_id:, **medicaid_attrs)
    kase = Corvid::Case.create!(
      patient_identifier: patient_id,
      facility_identifier: "fac_test"
    )
    pending_referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: referral_id,
      facility_identifier: "fac_test"
    )
    medicaid = pending_referral.alternate_resource_checks.find_or_create_by!(resource_type: "medicaid") do |check|
      check.status = "not_checked"
    end
    medicaid.update!(
      status: "pending_enrollment",
      eligibility_group_source: "staff_entry",
      eligibility_group_set_at: Time.current,
      **medicaid_attrs
    )
    pending_referral
  end

  def truncate_corvid_claim_graph!
    conn = ActiveRecord::Base.connection
    %w[
      corvid_determinations corvid_claim_submissions corvid_eligibility_checklists
      corvid_alternate_resource_checks corvid_prc_referrals corvid_cases
    ].each do |table|
      conn.execute("TRUNCATE #{table} CASCADE")
    end
  end

  def fresh_claim_row(claim_id)
    Corvid::ClaimSubmission.uncached do
      Corvid::ClaimSubmission.unscoped.find(claim_id)
    end
  end

  def submission_outcome_unknown_row?(row)
    row.submission_outcome_unknown_at.present?
  end

  def assert_override_spent_row!(row)
    assert_nil row.medicaid_hold_override_reason_token
    assert_nil row.medicaid_hold_override_by_identifier
    assert_nil row.medicaid_hold_overridden_at
  end

  def build_claim_for(referral, service_date: Date.new(2027, 2, 1))
    Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT,
      facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier,
      referral_identifier: referral.referral_identifier,
      claim_type: "professional",
      service_date: service_date,
      billed_amount: 100.0,
      status: "draft"
    )
  end

  def referral_at(facility, identifier, patient: "TEST,PATIENT GATE-R1-#{SecureRandom.hex(2)}")
    kase = Corvid::Case.create!(patient_identifier: patient, facility_identifier: facility)
    Corvid::PrcReferral.create!(case: kase, referral_identifier: identifier, facility_identifier: facility)
  end

  def authorize!(referral)
    referral.submit!
    referral.begin_eligibility_review!
    referral.reload
    checklist = referral.eligibility_checklist
    Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
      fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
      kwargs = {}
      kwargs[:source] = "test_fixture" if fields.key?(:source)
      kwargs[:by] = "usr_submitter" if fields.key?(:by)
      checklist.verify_item!(item, **kwargs)
    end
    referral.reload
    referral.request_management_approval!
    referral.pending_approval_by = "usr_other_approver"
    referral.approve_management!
    referral.reload
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.reload
    exhaust_alternate_resources!(referral)
    referral.complete_priority_assignment!
    referral.reload
    referral.authorize! if referral.may_authorize? && !referral.committee_review?
    referral.reload
  end

  def stub_submit_claim!
    calls = []
    Corvid.adapter.define_singleton_method(:submit_claim) do |data|
      calls << data
      { claim_identifier: "CLM-GATE-R1-#{calls.size}", status: "accepted" }
    end
    calls
  end
end
