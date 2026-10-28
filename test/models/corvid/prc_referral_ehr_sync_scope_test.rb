# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 pin A: EHR sync is narrowed to committed authorize,
# deny, and defer only. In-progress transitions and cancel must not call
# update_referral.
module Corvid
  class PrcReferralEhrSyncScopeTest < ActiveSupport::TestCase
    TENANT = "tnt_ehr_scope"
    FACILITY = "fac_ehr_scope"
    PATIENT = "pt_ehr_scope"

    IN_FLIGHT_SYNC_EVENTS = [
      [ :submit!, "submitted" ],
      [ :begin_eligibility_review!, "eligibility_review" ],
      [ :request_management_approval!, "management_approval" ],
      [ :approve_management!, "alternate_resource_review" ],
      [ :verify_alternate_resources!, "priority_assignment" ],
      [ :complete_priority_assignment!, "committee_review" ]
    ].freeze

    teardown do
      Corvid.reset_configuration!
    end

    test "authorize! syncs authorized CHS status exactly once after commit" do
      referral = with_tenant(TENANT) { referral_ready_to_authorize! }
      updates, = track_ehr_updates { referral.authorize! }

      syncs = authorized_syncs(updates)
      assert_equal 1, syncs.size, "expected one authorized sync, got #{updates.inspect}"
      assert_equal referral.referral_identifier, syncs.first.first
    end

    test "non-bang authorize followed by save! syncs authorized CHS status exactly once" do
      referral = with_tenant(TENANT) { referral_ready_to_authorize! }
      updates, = track_ehr_updates do
        assert referral.authorize
        referral.save!
      end

      assert_equal 1, authorized_syncs(updates).size,
        "expected one authorized sync, got #{updates.inspect}"
    end

    test "mark_denied! syncs denied CHS status exactly once after commit" do
      referral = with_tenant(TENANT) { referral_in_eligibility_review! }
      updates, = track_ehr_updates { referral.mark_denied! }

      denied = updates.select { |(_, params)| params[:chs_approval_status] == "D" }
      assert_equal 1, denied.size, "expected one denied sync, got #{updates.inspect}"
    end

    test "mark_deferred! syncs deferred CHS status as P exactly once after commit" do
      referral = with_tenant(TENANT) { referral_in_priority_assignment_for_deferral! }
      updates, = track_ehr_updates { referral.mark_deferred! }

      deferred = updates.select { |(_, params)| params[:chs_approval_status] == "P" }
      assert_equal 1, deferred.size, "expected one deferred sync, got #{updates.inspect}"
    end

    test "cancel! does not call update_referral" do
      referral = with_tenant(TENANT) { draft_referral! }
      updates, = track_ehr_updates { referral.cancel! }

      assert_equal "cancelled", referral.reload.status
      assert_empty updates,
        "cancel must not sync to EHR when CHS_STATUS_MAP has no cancel code, got #{updates.inspect}"
    end

    test "non-bang cancel followed by save! does not call update_referral" do
      referral = with_tenant(TENANT) { draft_referral! }
      updates, = track_ehr_updates do
        assert referral.cancel
        referral.save!
      end

      assert_equal "cancelled", referral.reload.status
      assert_empty updates, "cancel must not sync to EHR, got #{updates.inspect}"
    end

    test "return_to_eligibility_review! from exception_review does not call update_referral" do
      referral = with_tenant(TENANT) do
        referral = draft_referral!
        referral.update_column(:status, "exception_review")
        referral.reload
      end
      updates, = track_ehr_updates { assert referral.return_to_eligibility_review! }

      assert_equal "eligibility_review", referral.reload.status
      assert_empty updates,
        "transition to eligibility_review from exception_review must not sync to EHR, got #{updates.inspect}"
    end

    IN_FLIGHT_SYNC_EVENTS.each do |event, expected_status|
      test "#{event} to #{expected_status} does not call update_referral" do
        referral = with_tenant(TENANT) { referral_before(event) }
        updates, = track_ehr_updates { assert referral.public_send(event), "expected #{event} to succeed" }

        assert_equal expected_status, referral.reload.status
        assert_empty updates,
          "in-flight transition #{event} must not sync to EHR, got #{updates.inspect}"
      end
    end

    private

    def track_ehr_updates
      updates = []
      Corvid.configure { |c| c.on_provenance = nil }
      with_tenant(TENANT) do
        Corvid.adapter.define_singleton_method(:update_referral) do |identifier, params|
          updates << [ identifier, params.dup ]
          true
        end
        yield
      end
      [ updates ]
    end

    def authorized_syncs(updates)
      updates.select { |(_, params)| params[:chs_approval_status] == "A" }
    end

    def draft_referral!
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_ehr_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY
      )
    end

    def referral_in_eligibility_review!
      referral = draft_referral!
      referral.submit!
      referral.begin_eligibility_review!
      referral.reload
    end

    def referral_in_priority_assignment_for_deferral!
      referral = referral_in_eligibility_review!
      complete_checklist_and_management!(referral)
      exhaust_alternate_resources!(referral)
      referral.verify_alternate_resources!
      referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
      referral.reload
    end

    def referral_ready_to_authorize!
      referral = referral_in_priority_assignment_for_deferral!
      referral.update!(medical_priority: 3, estimated_cost: 75_000)
      referral.complete_priority_assignment!
      assert referral.committee_review?, "expected committee_review before authorize"
      referral.reload
    end

    def complete_checklist_only!(referral)
      checklist = referral.eligibility_checklist
      EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
        fields = EligibilityChecklist::ITEM_FIELDS.fetch(item)
        kwargs = {}
        kwargs[:source] = "test_fixture" if fields.key?(:source)
        kwargs[:by] = "usr_submitter" if fields.key?(:by)
        checklist.verify_item!(item, **kwargs)
      end
      referral.reload
    end

    def complete_checklist_and_management!(referral)
      complete_checklist_only!(referral)
      referral.request_management_approval!
      referral.pending_approval_by = "usr_mgr_other"
      referral.approve_management!
    end

    def referral_before(event)
      case event
      when :submit!
        draft_referral!
      when :begin_eligibility_review!
        referral_in_eligibility_review!.tap { |r| r.update_column(:status, "submitted") && r.reload }
      when :request_management_approval!
        referral = referral_in_eligibility_review!
        complete_checklist_only!(referral)
        referral.update_column(:status, "eligibility_review")
        referral.reload
      when :approve_management!
        referral = referral_in_eligibility_review!
        complete_checklist_only!(referral)
        referral.request_management_approval!
        referral.update_column(:status, "management_approval")
        referral.pending_approval_by = "usr_mgr_other"
        referral.reload
      when :verify_alternate_resources!
        referral = referral_in_eligibility_review!
        complete_checklist_and_management!(referral)
        exhaust_alternate_resources!(referral)
        referral.update_column(:status, "alternate_resource_review")
        referral.reload
      when :complete_priority_assignment!
        referral = referral_in_priority_assignment_for_deferral!
        referral.update!(medical_priority: 3, estimated_cost: 75_000)
        referral.reload
      else
        flunk "unhandled event #{event}"
      end
    end
  end
end
