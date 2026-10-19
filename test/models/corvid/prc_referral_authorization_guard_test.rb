# frozen_string_literal: true

require "test_helper"

module Corvid
  class PrcReferralAuthorizationGuardTest < ActiveSupport::TestCase
    TENANT = "tnt_auth_guard"
    FACILITY = "fac_test"
    PATIENT = "pt_test_001"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    # -- verify_alternate_resources guard ------------------------------------

    test "zero alternate resource checks blocks verify_alternate_resources" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review

        refute referral.alternate_resources_exhausted?
        refute referral.may_verify_alternate_resources?
        refute referral.verify_alternate_resources!

        assert_equal "alternate_resource_review", referral.status
      end
    end

    test "partial alternate resource set blocks verify_alternate_resources" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        %w[medicare_a medicaid private_insurance].each do |type|
          referral.alternate_resource_checks.create!(resource_type: type, status: "not_enrolled")
        end

        refute referral.verify_alternate_resources!
        assert_equal "alternate_resource_review", referral.status
      end
    end

    test "enrolled resource blocks verify with authorization_blockers entry" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(referral, "medicaid" => "enrolled")

        blockers = referral.authorization_blockers
        assert_includes blockers, "medicaid: enrolled (coordination of benefits not complete)"
        refute referral.verify_alternate_resources!
        assert_equal "alternate_resource_review", referral.status
      end
    end

    test "enrolled changed to coordinated unblocks verify through authorization" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(referral, "medicaid" => "enrolled")

        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update!(status: "coordinated")

        assert referral.alternate_resources_exhausted?
        assert_empty referral.authorization_blockers
        assert referral.verify_alternate_resources!
        assert_equal "priority_assignment", referral.status

        referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
        assert referral.complete_priority_assignment!
        assert_equal "authorized", referral.status
      end
    end

    test "pending_enrollment checking and not_checked block verify" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(
          referral,
          "state_program" => "pending_enrollment",
          "workers_comp" => "checking",
          "charity_care" => "not_checked"
        )

        refute referral.verify_alternate_resources!
        assert_equal "alternate_resource_review", referral.status

        blockers = referral.authorization_blockers
        assert_includes blockers, "charity_care: not checked"
        assert_includes blockers, "workers_comp: checking"
        assert_includes blockers, "state_program: pending enrollment"
        assert_equal blockers.sort, blockers
      end
    end

    test "missing check row blocks with not checked blocker" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(referral)
        referral.alternate_resource_checks.find_by(resource_type: "charity_care")&.destroy!

        blockers = referral.authorization_blockers
        assert_includes blockers, "charity_care: not checked"
        refute referral.verify_alternate_resources!
      end
    end

    test "all twelve determined allows verify complete_priority_assignment and authorized" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(
          referral,
          "medicare_a" => "not_enrolled",
          "medicaid" => "denied",
          "private_insurance" => "exhausted",
          "va_benefits" => "coordinated"
        )

        assert referral.may_verify_alternate_resources?
        assert referral.verify_alternate_resources!
        referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)

        assert referral.may_complete_priority_assignment?
        assert referral.complete_priority_assignment!
        assert_equal "authorized", referral.status
      end
    end

    test "re-verified enrolled after priority_assignment blocks authorize and complete_priority_assignment" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(referral)
        assert referral.verify_alternate_resources!
        referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)

        referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "enrolled")

        refute referral.may_authorize?
        refute referral.authorize!
        refute referral.complete_priority_assignment!
        assert_equal "priority_assignment", referral.status
      end
    end

    # -- committee path ------------------------------------------------------

    test "committee approval blocked when not exhausted then allowed when exhausted" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(referral)
        assert referral.verify_alternate_resources!
        referral.update!(medical_priority: 3, estimated_cost: 5_000)
        assert referral.complete_priority_assignment!
        assert_equal "committee_review", referral.status

        review = CommitteeReview.create!(
          prc_referral: referral,
          committee_date: Date.current,
          decision: "approved",
          approved_amount: 5_000,
          facility_identifier: FACILITY,
          reviewer_identifier: "rv_test"
        )

        referral.alternate_resource_checks.find_by!(resource_type: "medicare_a").update!(status: "enrolled")
        review.apply_to_referral!
        assert_equal "committee_review", referral.reload.status

        create_all_determined_checks(referral)
        review.apply_to_referral!
        assert_equal "authorized", referral.reload.status
      end
    end

    # -- emergency -----------------------------------------------------------

    test "emergent referral with medical priority 1 is blocked the same way" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        referral.update!(medical_priority: 1, emergency_flag: true)
        seed_adapter(referral, emergent: true)

        refute referral.verify_alternate_resources!
        assert_equal "alternate_resource_review", referral.status

        create_all_determined_checks(referral)
        assert referral.verify_alternate_resources!
      end
    end

    # -- authorization_blockers ------------------------------------------------

    test "authorization_blockers empty when exhausted and sorted when not" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(
          referral,
          "medicaid" => "enrolled",
          "medicare_a" => "checking",
          "tribal_program" => "not_checked"
        )

        blockers = referral.authorization_blockers
        assert_equal(
          [
            "medicaid: enrolled (coordination of benefits not complete)",
            "medicare_a: checking",
            "tribal_program: not checked"
          ],
          blockers
        )

        create_all_determined_checks(referral)
        assert_empty referral.authorization_blockers
      end
    end

    test "alternate_resources_exhausted delegates to AlternateResourceCheck.all_exhausted?" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(referral)

        assert_equal AlternateResourceCheck.all_exhausted?(referral), referral.alternate_resources_exhausted?
      end
    end

    test "PriorAuthorizationService auto_authorizable true when coordinated among twelve determined" do
      with_tenant(TENANT) do
        referral = create_referral_record
        referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
        create_all_determined_checks(referral, "medicaid" => "coordinated")

        assert PriorAuthorizationService.auto_authorizable?(referral)
      end
    end

    # -- other transitions unaffected ----------------------------------------

    test "submit cancel and deny are unaffected by missing alternate resource checks" do
      with_tenant(TENANT) do
        draft = create_referral_record
        assert draft.submit!
        assert_equal "submitted", draft.status

        in_eligibility = create_referral_record
        in_eligibility.submit!
        in_eligibility.begin_eligibility_review!
        assert in_eligibility.mark_denied!
        assert_equal "denied", in_eligibility.status

        cancellable = referral_in_alternate_resource_review
        assert cancellable.cancel!
        assert_equal "cancelled", cancellable.status
      end
    end

    test "return_to_eligibility_review still fires from alternate_resource_review without checks" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        assert referral.return_to_eligibility_review!
        assert_equal "eligibility_review", referral.status
      end
    end

    private

    def create_referral_record
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        estimated_cost: 5_000
      )
    end

    def seed_adapter(referral, emergent: false)
      Corvid.adapter.add_referral(
        referral.referral_identifier,
        patient_identifier: PATIENT,
        status: "pending",
        estimated_cost: referral.estimated_cost || 5_000,
        emergent: emergent,
        urgent: emergent,
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

    def create_all_determined_checks(referral, status_overrides = {})
      AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        check = referral.alternate_resource_checks.find_or_initialize_by(resource_type: type)
        check.status = status_overrides.fetch(type, "not_enrolled")
        check.save!
      end
      referral.alternate_resource_checks.reload
    end
  end
end
