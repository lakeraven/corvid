# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 finding 3: a publication mark from an unsaved AASM event
# must not survive reload or attribute restore and poison a later direct status
# write into syncing to the EHR.
module Corvid
  class PrcReferralStalePublicationMarkTest < ActiveSupport::TestCase
    TENANT = "tnt_stale_mark"
    FACILITY = "fac_stale_mark"
    PATIENT = "pt_test_668"

    teardown do
      Corvid.reset_configuration!
    end

    test "non-bang authorize discarded by reload does not publish on direct status update" do
      ehr_updates = []
      provenance_activities = []
      configure_trackers!(ehr_updates, provenance_activities)

      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!

        assert referral.authorize
        referral.reload
        referral.update!(status: "authorized")

        assert_equal "authorized", referral.reload.status
        assert_empty authorized_ehr_syncs(ehr_updates),
          "direct status write after discarded event must not sync, got #{ehr_updates.inspect}"
        assert_empty provenance_activities,
          "direct status write after discarded event must not record provenance, got #{provenance_activities.inspect}"
      end
    end

    test "non-bang authorize discarded by restore_attributes does not publish on direct status update" do
      ehr_updates = []
      provenance_activities = []
      configure_trackers!(ehr_updates, provenance_activities)

      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!

        assert referral.authorize
        referral.restore_attributes
        referral.update!(status: "authorized")

        assert_equal "authorized", referral.reload.status
        assert_empty authorized_ehr_syncs(ehr_updates),
          "direct status write after restore_attributes must not sync, got #{ehr_updates.inspect}"
        assert_empty provenance_activities,
          "direct status write after restore_attributes must not record provenance, got #{provenance_activities.inspect}"
      end
    end

    private

    def configure_trackers!(ehr_updates, provenance_activities)
      Corvid.configure do |c|
        c.on_provenance = ->(**attrs) { provenance_activities << attrs[:activity] }
      end
      Corvid.adapter.define_singleton_method(:update_referral) do |identifier, params|
        ehr_updates << [ identifier, params.dup ]
        true
      end
    end

    def authorized_ehr_syncs(updates)
      updates.select { |(_, params)| params[:chs_approval_status] == "A" }
    end

    def draft_referral!
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_stale_668_#{SecureRandom.hex(3)}",
        facility_identifier: FACILITY
      )
    end

    def referral_in_eligibility_review!
      referral = draft_referral!
      referral.submit!
      referral.begin_eligibility_review!
      referral.reload
    end

    def referral_ready_to_authorize!
      referral = referral_in_eligibility_review!
      complete_checklist_and_management!(referral)
      exhaust_alternate_resources!(referral)
      referral.verify_alternate_resources!
      referral.update!(medical_priority: 3, estimated_cost: 75_000)
      referral.complete_priority_assignment!
      assert referral.committee_review?, "expected committee_review before authorize"
      exhaust_alternate_resources!(referral, date_of_service: Date.current, as_of: Time.current)
      referral.reload
    end

    def complete_checklist_and_management!(referral)
      checklist = referral.eligibility_checklist
      EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
        fields = EligibilityChecklist::ITEM_FIELDS.fetch(item)
        kwargs = {}
        kwargs[:source] = "test_fixture" if fields.key?(:source)
        kwargs[:by] = "usr_submitter" if fields.key?(:by)
        checklist.verify_item!(item, **kwargs)
      end
      referral.reload
      referral.request_management_approval!
      referral.pending_approval_by = "usr_mgr_stale_668"
      referral.approve_management!
    end
  end
end
