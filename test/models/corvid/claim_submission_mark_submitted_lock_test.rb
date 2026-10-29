# frozen_string_literal: true

require "test_helper"

# Failing specs for mark_submitted! lock ordering (#639 / PR #688):
# gates and alternate-resource re-check must run under the patient advisory
# lock and row lock, not before with_medicaid_submission_lock.
class Corvid::ClaimSubmissionMarkSubmittedLockTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  TENANT = "tnt_test"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup { travel_to RETRO_SCENARIO_TIME }

  teardown do
    travel_back
    restore_with_medicaid_submission_lock!
    Corvid::TenantContext.reset!
    truncate_corvid_claim_graph!
  end

  test "plain mark_submitted! raises AlternateResourcesNotCurrent when own referral medicare_a enrolls after pre-lock gates and before lock" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      identifier = "CLM-MS-ARC-GAP-#{SecureRandom.hex(3)}"
      hook_mark_submitted_pre_lock_gap!(claim.id) { enroll_medicare_a_on_own_referral!(claim.id) }

      assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) do
        claim.mark_submitted!(claim_identifier: identifier)
      end

      row = fresh_claim_row(claim.id)
      assert_draft_not_marked_submitted!(row)
    end
  end

  test "plain mark_submitted! raises ReferralNotAuthorized when own referral is de-authorized after pre-lock gates and before lock" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      identifier = "CLM-MS-AUTH-GAP-#{SecureRandom.hex(3)}"
      hook_mark_submitted_pre_lock_gap!(claim.id) { deauthorize_claim_own_referral!(claim.id) }

      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) do
        claim.mark_submitted!(claim_identifier: identifier)
      end

      row = fresh_claim_row(claim.id)
      assert_draft_not_marked_submitted!(row)
    end
  end

  # Marker is set on a clear draft (no pending-Medicaid hold) so
  # confirm_submission_not_sent! in the gap does not re-arm the hold
  # before the lock; phase-B spend already cleared the override on the
  # row, and after confirm the hold would block with HeldForPendingMedicaid
  # instead of exposing the pre-lock marker vs lock gate skip.
  test "mark_submitted! with outcome-unknown marker does not record claim when confirm_submission_not_sent! clears marker before lock and own referral fails gates" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      Corvid::ClaimSubmission.where(id: claim.id).update_all(submission_outcome_unknown_at: Time.current)
      claim = Corvid::ClaimSubmission.find(claim.id)
      enroll_medicare_a_on_own_referral!(claim.id)
      before = fresh_claim_row(claim.id)
      assert submission_outcome_unknown_row?(before)
      assert_equal "draft", before.status
      assert_nil before.claim_identifier

      identifier = "CLM-MS-MARKER-RACE-#{SecureRandom.hex(3)}"
      hook_mark_submitted_pre_lock_gap!(claim.id) do
        peer = Corvid::ClaimSubmission.find(claim.id)
        peer.confirm_submission_not_sent!(by_identifier: "usr_ms_lock_gap")
      end

      assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) do
        claim.mark_submitted!(claim_identifier: identifier)
      end

      row = fresh_claim_row(claim.id)
      assert_equal before.status, row.status
      assert_nil before.claim_identifier
      assert_nil row.claim_identifier
      refute submission_outcome_unknown_row?(row)
    end
  end

  test "mark_submitted! while outcome unknown still records identifier when own referral medicare_a enrolls before call" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      enroll_medicare_a_on_own_referral!(claim.id)
      identifier = "CLM-MS-RECON-OK-#{SecureRandom.hex(3)}"

      claim.mark_submitted!(claim_identifier: identifier)

      row = fresh_claim_row(claim.id)
      refute submission_outcome_unknown_row?(row)
      assert_equal identifier, row.claim_identifier
      assert_equal "submitted", row.status
      assert row.submitted_at.present?
    end
  end

  test "plain mark_submitted! with current own referral records identifier" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      identifier = "CLM-MS-PLAIN-OK-#{SecureRandom.hex(3)}"

      claim.mark_submitted!(claim_identifier: identifier)

      row = fresh_claim_row(claim.id)
      assert_equal identifier, row.claim_identifier
      assert_equal "submitted", row.status
      assert row.submitted_at.present?
    end
  end

  private

  @with_medicaid_submission_lock_original = nil

  class << self
    attr_accessor :with_medicaid_submission_lock_original
  end

  def hook_mark_submitted_pre_lock_gap!(claim_id)
    gap_done = false
    original = with_medicaid_submission_lock_original_method
    Corvid::ClaimSubmission.define_method(:with_medicaid_submission_lock) do |&blk|
      unless gap_done
        gap_done = true
        yield claim_id
      end
      original.bind_call(self, &blk)
    end
  end

  def with_medicaid_submission_lock_original_method
    self.class.with_medicaid_submission_lock_original ||=
      Corvid::ClaimSubmission.instance_method(:with_medicaid_submission_lock)
  end

  def restore_with_medicaid_submission_lock!
    original = self.class.with_medicaid_submission_lock_original
    return unless original

    Corvid::ClaimSubmission.define_method(:with_medicaid_submission_lock, original)
  end

  def assert_draft_not_marked_submitted!(row)
    assert_equal "draft", row.status
    assert_nil row.claim_identifier
    assert_nil row.submitted_at
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
    referral = referral_at("fac_test", "REF-MS-LOCK-#{SecureRandom.hex(3)}")
    authorize!(referral)
    service_date = Date.new(2027, 2, 1)
    exhaust_alternate_resources!(referral, date_of_service: service_date, as_of: Time.current)
    referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
    seed_patient_pending_medicaid_on_referral!(
      patient_id: referral.case.patient_identifier,
      referral_id: "REF-PEND-MS-#{SecureRandom.hex(3)}",
      application_date: Date.new(2027, 3, 15),
      application_date_source: "staff_entry",
      medicaid_state_code: "XA",
      eligibility_group: "expansion_adult"
    )
    build_claim_for(referral, service_date: service_date).tap(&:save!)
  end

  def clear_to_submit_draft_claim!
    referral = referral_at("fac_test", "REF-MS-CLEAR-#{SecureRandom.hex(3)}")
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

  def referral_at(facility, identifier, patient: "TEST,PATIENT MS-LOCK-#{SecureRandom.hex(2)}")
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
end
