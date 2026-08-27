# frozen_string_literal: true

require "test_helper"

module Corvid
  # Cancellation semantics: `cancel` is only permitted from in-flight
  # (non-terminal) states. The four terminal states — authorized, denied,
  # deferred, cancelled — are genuine end states and cannot be cancelled.
  class PrcReferralCancelTest < ActiveSupport::TestCase
    TENANT = "tnt_cancel"
    FACILITY = "fac_cancel"

    IN_FLIGHT_STATES = %i[
      draft submitted eligibility_review management_approval
      alternate_resource_review priority_assignment
      committee_review exception_review
    ].freeze

    TERMINAL_STATES = %i[authorized denied deferred cancelled].freeze

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    # -- cancel IS permitted from in-flight states --

    test "cancel fires from draft" do
      with_tenant(TENANT) do
        r = referral_in(:draft)
        assert r.may_cancel?
        assert r.cancel!
        assert_equal "cancelled", r.status
      end
    end

    test "cancel fires from management_approval" do
      with_tenant(TENANT) do
        r = referral_in(:management_approval)
        assert r.may_cancel?
        assert r.cancel!
        assert_equal "cancelled", r.status
      end
    end

    test "cancel is permitted from every in-flight state" do
      with_tenant(TENANT) do
        IN_FLIGHT_STATES.each do |state|
          r = referral_in(state)
          assert r.may_cancel?, "expected cancel permitted from #{state}"
          assert_includes r.aasm.events(permitted: true).map(&:name), :cancel,
            "expected :cancel in permitted events from #{state}"
        end
      end
    end

    # -- cancel is NOT permitted from terminal states --

    test "cancel is not permitted from any terminal state" do
      with_tenant(TENANT) do
        TERMINAL_STATES.each do |state|
          r = referral_in(state)
          assert_equal state.to_s, r.status
          refute r.may_cancel?, "expected cancel NOT permitted from terminal #{state}"
          refute_includes r.aasm.events(permitted: true).map(&:name), :cancel,
            "expected :cancel excluded from permitted events in terminal #{state}"
          # whiny_transitions: false — firing is a no-op that leaves the terminal intact
          refute r.cancel!, "expected cancel! to no-op from terminal #{state}"
          assert_equal state.to_s, r.status
        end
      end
    end

    private

    def create_referral
      kase = Case.create!(patient_identifier: "pt_cancel", facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        estimated_cost: 5_000
      )
    end

    # Drives a referral to the requested state. Low estimated cost keeps
    # priority assignment out of committee review unless we route there
    # explicitly.
    def referral_in(target)
      r = create_referral
      seed_adapter(r)
      return r if target == :draft

      r.submit!
      return r if target == :submitted

      r.begin_eligibility_review!
      return r if target == :eligibility_review

      complete_non_approval_checklist!(r)
      r.request_management_approval!
      return r if target == :management_approval

      r.pending_approval_by = "pr_mgr"
      r.approve_management!
      return r if target == :alternate_resource_review

      r.verify_alternate_resources!
      return r if target == :priority_assignment

      case target
      when :committee_review
        r.update!(medical_priority: 3) # priority >= 3 routes to committee
        r.complete_priority_assignment!
        assert_equal "committee_review", r.status
        r
      when :exception_review
        # exception_review is reached via the emergency-notification pathway;
        # place the record directly for a terminal-guard assertion.
        r.update!(status: "exception_review")
        r
      when :authorized
        r.complete_priority_assignment! # low cost → authorized directly
        r
      when :denied
        r.mark_denied!
        r
      when :deferred
        r.mark_deferred!
        r
      when :cancelled
        r.cancel!
        r
      else
        raise ArgumentError, "unknown target state: #{target}"
      end
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
        patient_identifier: "pt_cancel", status: "pending",
        estimated_cost: 5_000, emergent: false, urgent: false,
        chs_approval_status: "P", service_requested: "TEST")
    end
  end
end
