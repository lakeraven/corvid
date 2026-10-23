# frozen_string_literal: true

require "test_helper"

# Issue #675 / PR #693: Medicaid primary authorization must refuse committee
# routing using a fresh EHR read after reload, not a stale service_request memo.
module Corvid
  class MedicaidReferralWorkflowFreshEhrCommitteeTest < ActiveSupport::TestCase
    TENANT = "tnt_g693_wf_committee"
    FACILITY = "fac_g693"
    PATIENT = "TEST,PATIENT WF G693"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    test "authorize_with_medicaid_primary! refuses committee review when EHR priority rises after reload" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(medical_priority: 2, flagged_for_review: false)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: referral.estimated_cost,
          medical_priority_level: 2,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )

        assert_equal 2, referral.service_request.medical_priority_level
        refute referral.requires_committee?

        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: referral.estimated_cost,
          medical_priority_level: 4,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        status_before = referral.status
        medicaid_before = medicaid.attributes.slice("status", "checked_at", "policy_token")

        assert referral.requires_committee?,
          "workflow must see updated EHR priority after referral reload"

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        assert_equal medicaid_before, medicaid.reload.attributes.slice("status", "checked_at", "policy_token")
        refute referral.reload.authorized?
        assert_equal status_before, referral.status
        assert_equal 0, referral.committee_reviews.count
        refute_equal "A", Corvid.adapter.find_referral(referral.referral_identifier).chs_approval_status
      end
    end

    private

    def create_referral_record
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        medical_priority: 2,
        flagged_for_review: false,
        estimated_cost: 5_000
      )
    end

    def seed_adapter(referral)
      Corvid.adapter.add_referral(
        referral.referral_identifier,
        patient_identifier: PATIENT,
        status: "pending",
        estimated_cost: referral.estimated_cost,
        emergent: false,
        urgent: false,
        chs_approval_status: "P",
        service_requested: "TEST"
      )
    end

    def complete_non_approval_checklist!(referral)
      checklist = referral.eligibility_checklist || referral.create_eligibility_checklist!(
        tenant_identifier: referral.tenant_identifier,
        facility_identifier: referral.facility_identifier
      )

      checklist.verify_item!(:application_complete, by: "clerk_1")
      checklist.verify_item!(:identity_verified, source: "manual")
      checklist.verify_item!(:insurance_verified, source: "manual")
      checklist.verify_item!(:residency_verified, source: "manual")
      checklist.verify_item!(:enrollment_verified, source: "manual")
      checklist.verify_item!(:clinical_necessity_documented, source: "manual")
    end

    def referral_in_alternate_resource_review
      referral = create_referral_record
      seed_adapter(referral)
      referral.submit!
      referral.begin_eligibility_review!
      complete_non_approval_checklist!(referral)
      referral.request_management_approval!
      referral.pending_approval_by = "pr_mgr"
      referral.approve_management!
      assert_equal "alternate_resource_review", referral.status
      referral
    end

    def referral_ready_for_medicaid_primary_authorization
      referral = referral_in_alternate_resource_review
      create_all_determermined_checks(referral, "medicaid" => "enrolled")
      medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
      ensure_enrolled_medicaid_current_coverage!(medicaid)
      referral
    end

    def create_all_determermined_checks(referral, status_overrides = {})
      AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        check = referral.alternate_resource_checks.find_or_initialize_by(resource_type: type)
        check.status = status_overrides.fetch(type, "not_enrolled")
        check.checked_at = Time.current if check.status != "not_checked"
        if type == "medicaid" && check.status == "enrolled"
          check.coverage_start = Date.current.beginning_of_year
          check.coverage_end = Date.current.end_of_year + 1.year
        end
        check.save!
      end
      referral.alternate_resource_checks.reload
    end

    def ensure_enrolled_medicaid_current_coverage!(medicaid)
      medicaid.update!(
        checked_at: Time.current,
        coverage_start: Date.current.beginning_of_year,
        coverage_end: Date.current.end_of_year + 1.year
      )
      assert medicaid.current_for?(Date.current), "happy-path enrolled medicaid must be current_for? today"
    end
  end
end
