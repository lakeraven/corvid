# frozen_string_literal: true

require "test_helper"

# Repro specs for #639 / PR #688 D2: submit! must spend Medicaid overrides only at top level.
class Corvid::ClaimSubmissionOverrideTopLevelTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  TENANT = "tnt_test"
  PATIENT = "TEST,PATIENT TOP-LEVEL"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup { travel_to RETRO_SCENARIO_TIME }

  teardown do
    travel_back
    Corvid::TenantContext.reset!
    truncate_corvid_claim_graph!
  end

  test "submit! with override inside ClaimSubmission.transaction raises before adapter and keeps override" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      override_token = claim.medicaid_hold_override_reason_token
      submit_calls = stub_submit_claim!

      error = assert_raises(top_level_error_class) do
        Corvid::ClaimSubmission.transaction do
          claim.submit!
        end
      end

      assert_instance_of top_level_error_class, error
      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_equal override_token, row.medicaid_hold_override_reason_token
      assert row.medicaid_hold_overridden_at.present?
      assert_equal "draft", row.status
    end
  end

  test "submit! with override inside ActiveRecord::Base.transaction raises before adapter and keeps override" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_submit_claim!

      assert_raises(top_level_error_class) do
        ActiveRecord::Base.transaction do
          claim.submit!
        end
      end

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_equal "rt_medicaid_hold_override", row.medicaid_hold_override_reason_token
    end
  end

  test "submit! with override inside requires_new caller transaction raises before adapter and keeps override" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_submit_claim!

      assert_raises(top_level_error_class) do
        ActiveRecord::Base.transaction(requires_new: true) do
          claim.submit!
        end
      end

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_equal "rt_medicaid_hold_override", row.medicaid_hold_override_reason_token
    end
  end

  test "host transaction that would rescue post-send failure and rollback is refused when override is in force" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = []
      Corvid.adapter.define_singleton_method(:submit_claim) do |data|
        submit_calls << data
        { claim_identifier: "CLM-ROLLBACK-TRAP", status: "accepted" }
      end

      error = assert_raises(top_level_error_class) do
        Corvid::ClaimSubmission.transaction do
          begin
            claim.submit!
          rescue ActiveRecord::RecordInvalid
            raise ActiveRecord::Rollback
          end
        end
      end

      assert_instance_of top_level_error_class, error
      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_equal "rt_medicaid_hold_override", row.medicaid_hold_override_reason_token
      assert_equal "draft", row.status
      assert_nil row.submitted_at
    end
  end

  test "submit! without override proceeds inside a host transaction" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      submit_calls = stub_submit_claim!

      Corvid::ClaimSubmission.transaction do
        claim.submit!
      end

      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_equal "submitted", row.status
      assert_equal "CLM-SPEC-001", row.claim_identifier
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

  def top_level_error_class
    Corvid::ClaimSubmission::OverrideRequiresTopLevelSubmit
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
    referral = referral_at("fac_test", "REF-TOP-#{SecureRandom.hex(3)}")
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
    referral = referral_at("fac_test", "REF-TOP-CLEAR-#{SecureRandom.hex(3)}")
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
end
