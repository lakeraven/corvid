# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 finding 1: deferred EHR sync and provenance must follow the
# save that committed the decision, not the outermost transaction commit when an
# inner savepoint rolls the decision back.
module Corvid
  class PrcReferralSavepointPublicationTest < ActiveSupport::TestCase
    # Non-transactional so host outer commits and after_all_transactions_commit run
    # for real; transactional tests keep everything on one connection transaction and
    # mask savepoint versus commit boundaries.
    self.use_transactional_tests = false

    TENANT = "tnt_sp_pub"
    FACILITY = "fac_sp_pub"
    PATIENT = "pt_test_668"

    setup do
      @created_referral_ids = []
      @created_claim_ids = []
    end

    teardown do
      Corvid.reset_configuration!
      delete_created_fixture_rows!
    end

    test "rolled-back savepoint authorize does not sync or record provenance after outer commit" do
      ehr_updates = []
      provenance_target_ids = []
      configure_publication_trackers!(ehr_updates, provenance_target_ids)

      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!

        ActiveRecord::Base.transaction do
          referral.class.transaction(requires_new: true) do
            assert referral.authorize!
            raise ActiveRecord::Rollback
          end
        end

        refute referral.reload.authorized?
        assert_empty authorized_ehr_syncs(ehr_updates),
          "savepoint rollback must not publish authorization to EHR, got #{ehr_updates.inspect}"
        assert_empty provenance_target_ids,
          "savepoint rollback must not record authorization provenance, got #{provenance_target_ids.inspect}"
      end
    end

    test "rolled-back savepoint claim submission does not record provenance after outer commit" do
      provenance_target_ids = []

      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
          referral = referral_ready_to_authorize!
          referral.authorize!
          record_delivered_fulfilment!(referral)
          claim = draft_claim_for!(referral)

          Corvid.configure do |c|
            c.on_provenance = ->(**attrs) { provenance_target_ids << attrs[:target_id] }
          end

          ActiveRecord::Base.transaction do
            claim.class.transaction(requires_new: true) do
              claim.mark_submitted!(claim_identifier: "CLM-SP-ROLL-668")
              raise ActiveRecord::Rollback
            end
          end

          assert_equal "draft", claim.reload.status
          assert_nil claim.claim_identifier
          assert_empty provenance_target_ids,
            "savepoint rollback must not record submission provenance, got #{provenance_target_ids.inspect}"
        end
      end
    end

    test "host re-save of authorized status after rolled-back savepoint publishes exactly once" do
      ehr_updates = []
      provenance_target_ids = []
      configure_publication_trackers!(ehr_updates, provenance_target_ids)

      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!

        ActiveRecord::Base.transaction do
          referral.class.transaction(requires_new: true) do
            assert referral.authorize
            referral.save!
            raise ActiveRecord::Rollback
          end

          refute PrcReferral.find(referral.id).authorized?,
            "precondition: savepoint rolled back authorization in the database"

          # Host still holds the authorized status in memory and re-saves without
          # re-running the AASM event after the savepoint rolls back.
          referral.status = "authorized"
          referral.save!
        end

        assert referral.reload.authorized?
        syncs = authorized_ehr_syncs(ehr_updates)
        assert_equal 1, syncs.size,
          "expected exactly one authorized EHR sync after successful host save, got #{ehr_updates.inspect}"
        assert_equal referral.referral_identifier, syncs.first.first
        assert_equal 1, provenance_target_ids.size,
          "expected authorization provenance once, got #{provenance_target_ids.inspect}"
        assert_equal referral.id.to_s, provenance_target_ids.first
      end
    end

    private

    def configure_publication_trackers!(ehr_updates, provenance_target_ids)
      Corvid.configure do |c|
        c.on_provenance = ->(**attrs) { provenance_target_ids << attrs[:target_id] }
      end
      Corvid.adapter.define_singleton_method(:update_referral) do |identifier, params|
        ehr_updates << [ identifier, params.dup ]
        true
      end
    end

    def authorized_ehr_syncs(updates)
      updates.select { |(_, params)| params[:chs_approval_status] == "A" }
    end

    def delete_created_fixture_rows!
      claim_ids = @created_claim_ids
      Corvid::ClaimSubmission.unscoped.where(id: claim_ids).delete_all if claim_ids.present?

      ids = @created_referral_ids
      return if ids.blank?

      Corvid::CommitteeReview.unscoped.where(prc_referral_id: ids).delete_all
      Corvid::AlternateResourceCheck.unscoped.where(prc_referral_id: ids).delete_all
      Corvid::EligibilityChecklist.unscoped.where(prc_referral_id: ids).delete_all
      Corvid::ReferralFulfilmentReport.unscoped.where(prc_referral_id: ids).delete_all
      case_ids = Corvid::PrcReferral.unscoped.where(id: ids).pluck(:case_id)
      Corvid::PrcReferral.unscoped.where(id: ids).delete_all
      Corvid::Case.unscoped.where(id: case_ids).delete_all
      @created_referral_ids = []
      @created_claim_ids = []
    end

    def draft_claim_for!(referral)
      claim = ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: FACILITY,
        patient_identifier: referral.case.patient_identifier,
        referral_identifier: referral.referral_identifier,
        claim_type: "professional",
        service_date: Date.new(2025, 6, 10),
        billed_amount: 100.0,
        status: "draft"
      )
      assert_equal referral.id, claim.prc_referral_id
      @created_claim_ids << claim.id
      claim
    end

    def draft_referral!
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      referral = PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_test_668_#{SecureRandom.hex(3)}",
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
      referral.pending_approval_by = "usr_mgr_sp_668"
      referral.approve_management!
    end
  end
end
