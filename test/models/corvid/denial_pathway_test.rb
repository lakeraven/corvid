# frozen_string_literal: true

require "test_helper"

module Corvid
  class DenialPathwayTest < ActiveSupport::TestCase
    TENANT = "tnt_deny"
    FACILITY = "fac_deny"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    # -- Denial from eligibility_review --

    test "denied from eligibility_review" do
      with_tenant(TENANT) do
        r = referral_in(:eligibility_review)
        r.mark_denied!
        assert_equal "denied", r.status
      end
    end

    test "denied referral cannot be authorized" do
      with_tenant(TENANT) do
        r = referral_in(:eligibility_review)
        r.mark_denied!
        refute r.may_authorize?
      end
    end

    # -- Deferral from priority_assignment --

    test "deferred from priority_assignment" do
      with_tenant(TENANT) do
        r = referral_in(:priority_assignment)
        r.mark_deferred!
        assert_equal "deferred", r.status
      end
    end

    test "deferred referral cannot be authorized" do
      with_tenant(TENANT) do
        r = referral_in(:priority_assignment)
        r.mark_deferred!
        refute r.may_authorize?
      end
    end

    # -- Distinct outcomes --

    test "denied and deferred are distinct states" do
      with_tenant(TENANT) do
        denied = referral_in(:eligibility_review)
        denied.mark_denied!
        deferred = referral_in(:priority_assignment)
        deferred.mark_deferred!
        refute_equal denied.status, deferred.status
      end
    end

    test "CHS status map: authorized=A denied=D deferred=nil" do
      assert_equal "A", PrcReferral::CHS_STATUS_MAP["authorized"]
      assert_equal "D", PrcReferral::CHS_STATUS_MAP["denied"]
      assert_nil PrcReferral::CHS_STATUS_MAP["deferred"]
    end

    # -- Cancellation --

    test "draft can be cancelled" do
      with_tenant(TENANT) do
        r = create_referral
        r.cancel!
        assert_equal "cancelled", r.status
        refute r.may_submit?
      end
    end

    private

    def create_referral
      kase = Case.create!(patient_identifier: "pt_deny", facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        estimated_cost: 5_000
      )
    end

    def referral_in(target)
      r = create_referral
      seed_adapter(r)

      r.submit!
      return r if target == :submitted

      r.begin_eligibility_review!
      return r if target == :eligibility_review

      # eligibility_review → management_approval → alternate_resource_review → priority_assignment
      complete_non_approval_checklist!(r)
      r.request_management_approval!
      return r if target == :management_approval

      r.pending_approval_by = "pr_mgr"
      r.approve_management!
      return r if target == :alternate_resource_review

      r.verify_alternate_resources!
      return r if target == :priority_assignment

      r
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

    def seed_adapter(referral)
      Corvid.adapter.add_referral(referral.referral_identifier,
        patient_identifier: "pt_deny", status: "pending",
        estimated_cost: 5_000, emergent: false, urgent: false,
        chs_approval_status: "P", service_requested: "TEST")
    end
  end
end
