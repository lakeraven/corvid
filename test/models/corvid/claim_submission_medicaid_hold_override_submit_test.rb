# frozen_string_literal: true

require "test_helper"

# Override submit paths need real commits (phase A / B); not wrapped in a test transaction.
class Corvid::ClaimSubmissionMedicaidHoldOverrideSubmitTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  TENANT = "tnt_test"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup { travel_to RETRO_SCENARIO_TIME }

  teardown do
    travel_back
    Corvid::TenantContext.reset!
    truncate_corvid_claim_graph!
  end

  test "override_medicaid_hold! records override fields and allows submit!" do
    with_tenant(TENANT) do
      claim = held_draft_claim!
      submit_calls = stub_submit_claim!

      claim.override_medicaid_hold!(
        reason_token: "rt_medicaid_hold_override",
        by_identifier: "usr_billing_spec"
      )
      claim.reload
      assert_equal "rt_medicaid_hold_override", claim.medicaid_hold_override_reason_token
      assert_equal "usr_billing_spec", claim.medicaid_hold_override_by_identifier
      assert_not_nil claim.medicaid_hold_overridden_at

      claim.submit!

      assert_equal 1, submit_calls.size
      assert_equal "submitted", fresh_claim_row(claim.id).status
    end
  end

  test "successful override submit clears marker spends override and calls adapter once" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_equal "submitted", row.status
      assert_equal "CLM-SPEC-001", row.claim_identifier
      assert row.submitted_at.present?
      refute row.submission_outcome_unknown_at.present?
      assert_override_spent_row!(row)
    end
  end

  test "medicaid hold override columns clear after successful submit!" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      determination_count = Corvid::Determination.where(
        determinable_type: claim.class.name,
        determinable_id: claim.id
      ).count
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      assert_equal determination_count, Corvid::Determination.where(
        determinable_type: claim.class.name,
        determinable_id: claim.id
      ).count
    end
  end

  test "resubmit after rejection re-evaluates medicaid hold without a fresh override" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      stub_submit_claim!
      claim.submit!
      claim.mark_rejected!(reason_token: "rt_front_door")
      submit_calls = stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_empty submit_calls
      assert_equal "rejected", fresh_claim_row(claim.id).status
    end
  end

  test "nested submit! during adapter call allows only one clearinghouse submission" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      copy_a = Corvid::ClaimSubmission.find(claim.id)
      copy_b = Corvid::ClaimSubmission.find(claim.id)
      submit_calls = []
      nested_error = nil
      Corvid.adapter.define_singleton_method(:submit_claim) do |data|
        submit_calls << data
        if submit_calls.size == 1
          begin
            copy_b.submit!
          rescue Corvid::ClaimSubmission::SubmissionOutcomeUnknown => error
            nested_error = error
          end
        end
        { claim_identifier: "CLM-CONCURRENT-1", status: "accepted" }
      end

      copy_a.submit!

      assert_instance_of Corvid::ClaimSubmission::SubmissionOutcomeUnknown, nested_error
      assert_equal 1, submit_calls.size
      assert_equal "submitted", fresh_claim_row(claim.id).status
    end
  end

  test "stale in-memory copy cannot submit! after override was consumed" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      fresh = Corvid::ClaimSubmission.find(claim.id)
      stale = Corvid::ClaimSubmission.find(claim.id)
      submit_calls = stub_submit_claim!

      fresh.submit!

      assert_equal 1, submit_calls.size
      submit_calls.clear
      stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { stale.submit! }
      assert_empty submit_calls
      assert_equal "submitted", fresh_claim_row(fresh.id).status
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

  def assert_override_spent_row!(row)
    assert_nil row.medicaid_hold_override_reason_token
    assert_nil row.medicaid_hold_override_by_identifier
    assert_nil row.medicaid_hold_overridden_at
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
    referral = referral_at("fac_a", "REF-OV-SUB-#{SecureRandom.hex(3)}")
    authorize!(referral)
    service_date = Date.new(2027, 2, 1)
    exhaust_alternate_resources!(referral, date_of_service: service_date, as_of: Time.current)
    referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
    seed_patient_pending_medicaid_on_second_referral!(
      patient_id: referral.case.patient_identifier,
      application_date: Date.new(2027, 3, 15),
      application_date_source: "staff_entry",
      medicaid_state_code: "XA",
      eligibility_group: "expansion_adult"
    )
    build_claim_for(referral).tap(&:save!)
  end

  def seed_patient_pending_medicaid_on_second_referral!(patient_id:, **medicaid_attrs)
    kase = Corvid::Case.create!(patient_identifier: patient_id, facility_identifier: "fac_a")
    pending_referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "REF-PEND-#{SecureRandom.hex(3)}",
      facility_identifier: "fac_a"
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

  def referral_at(facility, identifier, patient_id: "pt-ov-sub-#{SecureRandom.hex(2)}")
    kase = Corvid::Case.create!(patient_identifier: patient_id, facility_identifier: facility)
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
      { claim_identifier: "CLM-SPEC-001", status: "accepted" }
    end
    calls
  end
end
