# frozen_string_literal: true

require "test_helper"

module Corvid
  class MedicaidReferralWorkflowTest < ActiveSupport::TestCase
    TENANT = "tnt_test"
    FACILITY = "fac_test"
    PATIENT = "TEST,PATIENT 001"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    test "authorize_with_medicaid_primary! coordinates enrolled medicaid and authorizes through AASM" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        assert medicaid.enrolled?, "precondition"
        refute referral.authorized?

        workflow = Corvid::MedicaidReferralWorkflow.new
        workflow.authorize_with_medicaid_primary!(referral)

        referral.reload
        medicaid.reload
        assert medicaid.coordinated?, "Medicaid primary payer is recorded by coordinating the check"
        assert_equal "authorized", referral.status
        assert referral.alternate_resources_exhausted?
        assert_empty referral.authorization_blockers
      end
    end

    test "authorize_with_medicaid_primary! refuses when medicaid is not enrolled and leaves checks unchanged" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determermined_checks(referral, "medicaid" => "not_enrolled")
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        before = medicaid.attributes.slice("status", "checked_at", "policy_token")

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/medicaid/, error.message)
        assert_match(/medicaid: not enrolled/, error.message)
        assert_equal before, medicaid.reload.attributes.slice("status", "checked_at", "policy_token")
        refute referral.authorized?
      end
    end

    test "authorize_with_medicaid_primary! refuses when medicaid check is missing" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determermined_checks(referral)
        referral.alternate_resource_checks.find_by(resource_type: "medicaid")&.destroy!

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_includes error.message, "medicaid: not checked"
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! refuses when medicaid is still verifying" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determermined_checks(referral, "medicaid" => "checking")

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_includes error.message, "medicaid: checking"
        assert_equal "checking", referral.alternate_resource_checks.find_by!(resource_type: "medicaid").status
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! rolls back medicaid coordination when authorization guard still blocks" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicare_a = referral.alternate_resource_checks.find_by!(resource_type: "medicare_a")
        medicare_a.update!(status: "enrolled", checked_at: Time.current)
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        assert medicaid.enrolled?

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_includes error.message, "medicare_a: enrolled (coordination of benefits not complete)"
        medicaid.reload
        assert medicaid.enrolled?, "coordination must not persist when authorization is refused"
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! rolls back when referral cannot authorize from its workflow state" do
      with_tenant(TENANT) do
        referral = create_referral_record
        seed_adapter(referral)
        create_all_determermined_checks(referral, "medicaid" => "enrolled")
        assert_equal "draft", referral.status

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/referral: draft/, error.message)
        assert referral.alternate_resource_checks.find_by!(resource_type: "medicaid").enrolled?
        refute referral.reload.authorized?
      end
    end

    test "constructor accepts an injected adapter per ADR 0005" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        fake = Corvid.adapter
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: fake)

        workflow.authorize_with_medicaid_primary!(referral)

        assert_equal "authorized", referral.reload.status
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
      medicaid.update!(checked_at: Time.current) unless medicaid.checked_at
      referral
    end

    def create_all_determermined_checks(referral, status_overrides = {})
      AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        check = referral.alternate_resource_checks.find_or_initialize_by(resource_type: type)
        check.status = status_overrides.fetch(type, "not_enrolled")
        check.checked_at = Time.current if check.status != "not_checked"
        check.save!
      end
      referral.alternate_resource_checks.reload
    end
  end
end
