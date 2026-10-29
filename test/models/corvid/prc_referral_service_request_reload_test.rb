# frozen_string_literal: true

require "test_helper"
require_relative "../../support/medicaid_priority_assignment_fresh_read_test_helper"

# Issue #675 / PR #693: reload must drop memoized EHR service_request so
# committee routing sees current adapter data.
module Corvid
  class PrcReferralServiceRequestReloadTest < ActiveSupport::TestCase
    include MedicaidPriorityAssignmentFreshReadTestHelper
    TENANT = "tnt_g693_stale_sr"
    FACILITY = "fac_g693"
    PATIENT = "TEST,PATIENT STALE"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    test "reload clears memoized service_request so requires_committee? reflects updated EHR priority" do
      with_tenant(TENANT) do
        kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
        referral = PrcReferral.create!(
          case: kase,
          referral_identifier: "rf_g693_stale",
          facility_identifier: FACILITY,
          estimated_cost: 100,
          medical_priority: 2,
          flagged_for_review: false
        )
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: 100,
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
          estimated_cost: 100,
          medical_priority_level: 4,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload

        assert_equal 4, Corvid.adapter.find_referral(referral.referral_identifier).medical_priority_level
        assert referral.requires_committee?,
          "after reload, requires_committee? must read fresh EHR medical_priority_level"
      end
    end

    test "complete_priority_assignment! routes to committee when EHR priority rises without reload" do
      with_tenant(TENANT) do
        referral = referral_at_priority_assignment
        referral.update_columns(medical_priority: 2, flagged_for_review: false, estimated_cost_cents: 500_000)
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

        assert_equal 4, Corvid.adapter.find_referral(referral.referral_identifier).medical_priority_level
        refute referral.requires_committee?,
          "precondition: stale memo must not reflect raised EHR priority until code is fixed"

        assert referral.complete_priority_assignment!,
          "must read fresh EHR priority at decision time, not memoized service_request"
        assert_equal "committee_review", referral.reload.status
        refute referral.authorized?
      end
    end

    test "complete_priority_assignment! does not authorize when fresh EHR read drops committee need but cost stays unknown" do
      with_tenant(TENANT) do
        referral = referral_at_priority_assignment
        configure_unknown_cost_two_read_scenario!(referral, patient_identifier: PATIENT)
        status_before = referral.status

        refute referral.complete_priority_assignment!,
          "unknown cost after a fresh read must not authorize when committee review is not required"
        referral.reload
        refute referral.authorized?
        assert_equal status_before, referral.status
        refute_equal "A", Corvid.adapter.find_referral(referral.referral_identifier).chs_approval_status
      end
    end

    private

    def create_referral_record
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_g675_cpa_#{SecureRandom.hex(3)}",
        facility_identifier: FACILITY,
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

    def create_all_determined_checks(referral)
      AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        check = referral.alternate_resource_checks.find_or_initialize_by(resource_type: type)
        check.status = "not_enrolled"
        check.save!
        stamp_alternate_resource_check_current!(check) unless check.not_checked? || check.checking?
      end
      referral.alternate_resource_checks.reload
    end

    def referral_at_priority_assignment
      referral = referral_in_alternate_resource_review
      create_all_determined_checks(referral)
      assert referral.verify_alternate_resources!
      assert_equal "priority_assignment", referral.status
      referral
    end
  end
end
