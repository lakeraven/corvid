# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 F2–F5b: stale publication marks must not sync to the EHR
# or record provenance after bypass writes, aborted saves, or dup copies.
module Corvid
  class PrcReferralPublicationMarkHygieneTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    TENANT = "tnt_pub_hygiene_668"
    FACILITY = "fac_pub_hygiene_668"
    PATIENT = "pt_pub_hygiene_668"

    setup do
      @created_referral_ids = []
      @ehr_updates = []
      @provenance_target_ids = []
      configure_publication_trackers!
    end

    teardown do
      Corvid.reset_configuration!
      delete_created_fixture_rows!
    end

    test "update_columns after non-bang authorize does not publish on direct authorized write" do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        reset_trackers!

        assert referral.authorize
        referral.update_columns(status: "committee_review")
        referral.update!(status: "authorized")

        assert_equal "authorized", referral.reload.status
        assert_no_publication!
      end
    end

    test "update_column after non-bang authorize does not publish on direct authorized write" do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        reset_trackers!

        assert referral.authorize
        referral.update_column(:status, "committee_review")
        referral.update!(status: "authorized")

        assert_equal "authorized", referral.reload.status
        assert_no_publication!
      end
    end

    test "rolled-back authorize savepoint then update_columns does not publish on authorized write" do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        reset_trackers!

        ActiveRecord::Base.transaction do
          PrcReferral.transaction(requires_new: true) do
            assert referral.authorize!
            raise ActiveRecord::Rollback
          end
        end
        refute PrcReferral.find(referral.id).authorized?

        referral.reload
        assert referral.authorize
        referral.update_columns(status: "committee_review")
        referral.update!(status: "authorized")

        assert_equal "authorized", referral.reload.status
        assert_no_publication!
      end
    end

    test "before_save abort during authorize leaves no sync or provenance" do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        reset_trackers!

        referral.define_singleton_method(:host_abort) { throw :abort }
        PrcReferral.before_save :host_abort, if: -> { instance_variable_get(:@probe_abort) }
        begin
          referral.instance_variable_set(:@probe_abort, true)
          ActiveRecord::Base.transaction do
            refute referral.authorize!
          end
          referral.instance_variable_set(:@probe_abort, false)

          assert_equal "committee_review", PrcReferral.find(referral.id).status
          assert_no_publication!
        ensure
          PrcReferral.skip_callback(:save, :before, :host_abort)
        end
      end
    end

    test "dup of referral after non-bang authorize does not publish on save" do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        reset_trackers!

        assert referral.authorize
        copy = referral.dup
        copy.referral_identifier = "dup_#{SecureRandom.hex(4)}"
        copy.save!
        @created_referral_ids << copy.id

        assert_no_publication!
      end
    end

    test "status assignment drops stale mark before authorized update publishes nothing" do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        reset_trackers!

        assert referral.authorize
        referral.status = "committee_review"
        referral.save!
        referral.update!(status: "authorized")

        assert_equal "authorized", referral.reload.status
        assert_no_publication!
      end
    end

    test "write_attribute status drops stale mark before authorized update publishes nothing" do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        reset_trackers!

        assert referral.authorize
        referral.write_attribute(:status, "committee_review")
        referral.save!
        referral.update!(status: "authorized")

        assert_equal "authorized", referral.reload.status
        assert_no_publication!
      end
    end

    private

    def configure_publication_trackers!
      ehr_updates = @ehr_updates
      provenance_target_ids = @provenance_target_ids
      Corvid.configure do |c|
        c.on_provenance = ->(**attrs) { provenance_target_ids << attrs[:target_id] }
      end
      Corvid.adapter.define_singleton_method(:update_referral) do |identifier, params|
        ehr_updates << [ identifier, params.dup ]
        true
      end
    end

    def reset_trackers!
      @ehr_updates.clear
      @provenance_target_ids.clear
    end

    def authorized_ehr_syncs
      @ehr_updates.select { |(_, params)| params[:chs_approval_status] == "A" }
    end

    def assert_no_publication!
      assert_empty authorized_ehr_syncs,
        "expected no authorized EHR sync, got #{@ehr_updates.inspect}"
      assert_empty @provenance_target_ids,
        "expected no provenance, got #{@provenance_target_ids.inspect}"
    end

    def delete_created_fixture_rows!
      ids = @created_referral_ids
      return if ids.blank?

      CommitteeReview.unscoped.where(prc_referral_id: ids).delete_all
      AlternateResourceCheck.unscoped.where(prc_referral_id: ids).delete_all
      EligibilityChecklist.unscoped.where(prc_referral_id: ids).delete_all
      case_ids = PrcReferral.unscoped.where(id: ids).pluck(:case_id)
      PrcReferral.unscoped.where(id: ids).delete_all
      Case.unscoped.where(id: case_ids).delete_all
      @created_referral_ids = []
    end

    def draft_referral!
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      referral = PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_hygiene_668_#{SecureRandom.hex(3)}",
        facility_identifier: FACILITY
      )
      @created_referral_ids << referral.id
      referral
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
      referral.pending_approval_by = "usr_mgr_hygiene_668"
      referral.approve_management!
    end
  end
end
