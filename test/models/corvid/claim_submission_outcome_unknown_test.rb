# frozen_string_literal: true

require "test_helper"

# Repro specs for #639 / PR #688 D1: unknown outcome after a spent Medicaid hold override.
class Corvid::ClaimSubmissionOutcomeUnknownTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other_outcome"
  PATIENT = "TEST,PATIENT OUTCOME-UNK"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup { travel_to RETRO_SCENARIO_TIME }

  teardown do
    travel_back
    Corvid::TenantContext.reset!
    truncate_corvid_claim_graph!
  end

  test "submit! spends override and marks submission_outcome_unknown_at when adapter raises Timeout::Error" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_adapter_raise!(Timeout::Error, "execution expired")

      error = assert_raises(Timeout::Error) { claim.submit! }

      assert_equal "execution expired", error.message
      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      assert submission_outcome_unknown_row?(row)
      assert_equal "draft", row.status
      assert_nil row.submitted_at
      assert_nil row.claim_identifier
    end
  end

  test "submit! spends override and marks unknown outcome when adapter raises read timeout" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_adapter_raise!(RuntimeError, "read timeout")

      assert_raises(RuntimeError) { claim.submit! }

      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      assert submission_outcome_unknown_row?(row)
    end
  end

  test "submit! raises SubmissionOutcomeUnknown and skips adapter while outcome is unknown" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      submit_calls = stub_submit_claim!

      error = assert_raises(outcome_unknown_error_class) { claim.submit! }

      assert_instance_of outcome_unknown_error_class, error
      assert_empty submit_calls
      assert submission_outcome_unknown_row?(fresh_claim_row(claim.id))
    end
  end

  test "override_medicaid_hold! raises SubmissionOutcomeUnknown and records nothing while outcome is unknown" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      determinations_before = determination_count_for(claim)

      error = assert_raises(outcome_unknown_error_class) do
        claim.override_medicaid_hold!(
          reason_token: "rt_should_not_record",
          by_identifier: "usr_blocked"
        )
      end

      assert_instance_of outcome_unknown_error_class, error
      row = fresh_claim_row(claim.id)
      assert_equal determinations_before, determination_count_for(claim)
      assert_nil row.medicaid_hold_override_reason_token
      assert submission_outcome_unknown_row?(row)
    end
  end

  test "confirm_submission_not_sent! clears marker appends staff_review Determination and allows resubmit" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      determinations_before = determination_count_for(claim)
      submit_calls = stub_submit_claim!

      claim.confirm_submission_not_sent!(by_identifier: "usr_recon_spec")
      row = fresh_claim_row(claim.id)
      refute submission_outcome_unknown_row?(row)

      determinations = new_determinations_since(claim, determinations_before)
      assert_equal 1, determinations.size
      det = determinations.first
      assert det.decision_method_staff_review?
      assert_equal "usr_recon_spec", det.determined_by_identifier

      claim.override_medicaid_hold!(
        reason_token: "rt_medicaid_hold_override",
        by_identifier: "usr_billing_spec"
      )
      claim.submit!

      assert_equal 1, submit_calls.size
      assert_equal "submitted", fresh_claim_row(claim.id).status
    end
  end

  test "mark_submitted! clears unknown outcome marker and records claim identifier" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      identifier = "CLM-CONFIRMED-SENT-#{SecureRandom.hex(3)}"

      claim.mark_submitted!(claim_identifier: identifier)

      row = fresh_claim_row(claim.id)
      refute submission_outcome_unknown_row?(row)
      assert_equal identifier, row.claim_identifier
      assert_equal "submitted", row.status
      assert row.submitted_at.present?
    end
  end

  test "plain save cannot set submission_outcome_unknown_at" do
    with_tenant(TENANT) do
      claim = held_draft_claim!
      assert claim.has_attribute?(:submission_outcome_unknown_at),
        "submission_outcome_unknown_at column must exist on corvid_claim_submissions"

      refute claim.update(submission_outcome_unknown_at: Time.current)
      assert claim.errors[:submission_outcome_unknown_at].present? ||
        claim.errors[:base].present?
      refute submission_outcome_unknown_row?(fresh_claim_row(claim.id))
    end
  end

  test "plain save cannot clear submission_outcome_unknown_at" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!

      refute claim.update(submission_outcome_unknown_at: nil)
      assert claim.errors[:submission_outcome_unknown_at].present? ||
        claim.errors[:base].present?
      assert submission_outcome_unknown_row?(fresh_claim_row(claim.id))
    end
  end

  test "submit! without override propagates adapter error and does not mark unknown outcome" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      submit_calls = stub_adapter_raise!(StandardError, "clearinghouse unavailable")

      assert_raises(StandardError) { claim.submit! }

      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_equal "draft", row.status
      assert_nil row.submitted_at
      assert_nil row.claim_identifier
      refute submission_outcome_unknown_row?(row)
    end
  end

  test "confirm_submission_not_sent! raises ArgumentError when marker is not set" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!

      error = assert_raises(ArgumentError) do
        claim.confirm_submission_not_sent!(by_identifier: "usr_recon")
      end
      assert_match(/not unknown/i, error.message)
      refute submission_outcome_unknown_row?(fresh_claim_row(claim.id))
    end
  end

  test "confirm_submission_not_sent! raises ArgumentError when by_identifier is blank" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!

      assert_raises(ArgumentError) do
        claim.confirm_submission_not_sent!(by_identifier: "")
      end
      assert submission_outcome_unknown_row?(fresh_claim_row(claim.id))
    end
  end

  test "failed confirm_submission_not_sent! leaves marker set and reloads the claim" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      singleton = Corvid::Determination.singleton_class
      original_create = singleton.instance_method(:create!)
      singleton.define_method(:create!) do |*_args, **_kwargs|
        raise ActiveRecord::RecordInvalid, Corvid::Determination.new
      end
      begin
        assert_raises(ActiveRecord::RecordInvalid) do
          claim.confirm_submission_not_sent!(by_identifier: "usr_fail_confirm")
        end
      ensure
        singleton.define_method(:create!, original_create)
      end

      claim.reload
      assert submission_outcome_unknown_row?(fresh_claim_row(claim.id))
      refute claim.submission_outcome_unknown_at.nil?,
        "in-memory row must reflect persisted marker after failed confirm"
    end
  end

  test "Interrupt from adapter marks unknown outcome and re-raises the same object" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      original = Interrupt.new("ctrl-c")
      Corvid.adapter.define_singleton_method(:submit_claim) { |_d| raise original }

      err = assert_raises(Interrupt) { claim.submit! }

      assert err.equal?(original)
      row = fresh_claim_row(claim.id)
      assert submission_outcome_unknown_row?(row)
      assert_override_spent_row!(row)
    end
  end

  test "submission_outcome_unknown marker is enforced when TenantContext differs from claim tenant" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      submit_calls = stub_submit_claim!

      with_tenant(OTHER_TENANT) do
        assert_raises(outcome_unknown_error_class) { claim.submit! }
      end

      assert_empty submit_calls
      assert submission_outcome_unknown_row?(fresh_claim_row(claim.id))
    end
  end

  private

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

  def outcome_unknown_error_class
    Corvid::ClaimSubmission::SubmissionOutcomeUnknown
  end

  def claim_in_outcome_unknown_state!
    claim = held_draft_with_override!
    stub_adapter_raise!(Timeout::Error, "execution expired")
    assert_raises(Timeout::Error) { claim.submit! }
    row = fresh_claim_row(claim.id)
    assert submission_outcome_unknown_row?(row), "expected unknown-outcome marker after adapter failure"
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
    referral = referral_at("fac_test", "REF-OUTCOME-#{SecureRandom.hex(3)}")
    authorize!(referral)
    medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
    medicaid.update!(
      status: "pending_enrollment",
      application_date: Date.new(2027, 3, 15),
      application_date_source: "staff_entry",
      medicaid_state_code: "XA",
      eligibility_group: "expansion_adult",
      eligibility_group_source: "staff_entry",
      eligibility_group_set_at: Time.current
    )
    build_claim_for(referral, service_date: Date.new(2027, 2, 1)).tap(&:save!)
  end

  def clear_to_submit_draft_claim!
    referral = referral_at("fac_test", "REF-CLEAR-OUTCOME-#{SecureRandom.hex(3)}")
    authorize!(referral)
    referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
    build_claim_for(referral, service_date: Date.new(2027, 2, 1)).tap(&:save!)
  end

  def build_claim_for(referral, service_date:)
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

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: PATIENT,
      facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase, referral_identifier: identifier, facility_identifier: facility
    )
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
      { claim_identifier: "CLM-SPEC-001", status: "accepted" }
    end
    calls
  end

  def stub_adapter_raise!(klass, message)
    calls = []
    Corvid.adapter.define_singleton_method(:submit_claim) do |data|
      calls << data
      raise klass, message
    end
    calls
  end

  def determination_count_for(claim)
    Corvid::Determination.where(
      determinable_type: claim.class.name,
      determinable_id: claim.id
    ).count
  end

  def new_determinations_since(claim, count_before)
    Corvid::Determination.where(
      determinable_type: claim.class.name,
      determinable_id: claim.id
    ).chronological.offset(count_before).to_a
  end
end
