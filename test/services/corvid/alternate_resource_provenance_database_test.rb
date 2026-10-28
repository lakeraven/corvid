# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Issue #668: database-level on_provenance failures must not abort the
# authorization/submission transaction. Non-transactional so a failing query in
# on_provenance does not abort the example's database transaction (reload and
# assertions still run); rows are removed in teardown.
class Corvid::AlternateResourceProvenanceDatabaseTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TENANT = "tnt_test"
  FACILITY = "fac_test"
  PATIENT = "pt-test-004"

  setup do
    @created_referral_ids = []
    @created_claim_ids = []
  end

  teardown do
    Corvid.reset_configuration!
    delete_created_fixture_rows!
  end

  test "on_provenance database failure does not roll back authorize! from priority_assignment" do
    with_tenant(TENANT) do
      referral = authorized_referral_ready_to_authorize!
      configure_db_failing_provenance!
      logged = []
      Rails.logger.stub(:error, ->(msg) { logged << msg }) do
        assert referral.authorize!
      end
      assert_equal "authorized", referral.reload.status
      assert logged.any? { |m| m.to_s.include?("Provenance hook failed") }
    end
  end

  test "on_provenance database failure does not roll back complete_priority_assignment! when it authorizes" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_ready_for_priority_completion!
        configure_db_failing_provenance!

        logged = []
        Rails.logger.stub(:error, ->(msg) { logged << msg }) do
          assert referral.complete_priority_assignment!
        end
        assert_equal "authorized", referral.reload.status
        assert logged.any? { |m| m.to_s.include?("Provenance hook failed") }
      end
    end
  end

  test "on_provenance database failure does not roll back committee apply_to_referral! authorization" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = committee_ready_referral!
        review = Corvid::CommitteeReview.create!(
          prc_referral: referral,
          committee_date: Date.current,
          decision: "approved",
          approved_amount: 5_000,
          facility_identifier: FACILITY,
          reviewer_identifier: "rv_prov_db"
        )
        configure_db_failing_provenance!

        logged = []
        Rails.logger.stub(:error, ->(msg) { logged << msg }) do
          review.apply_to_referral!
        end
        assert_equal "authorized", referral.reload.status
        assert logged.any? { |m| m.to_s.include?("Provenance hook failed") }
      end
    end
  end

  test "claim submit! does not call on_provenance when outer transaction rolls back" do
    provenance_calls = []

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at(FACILITY, "REF-CLAIM-ROLL-SUBMIT")
        authorize_referral!(referral)
        claim = build_claim(referral, "REF-CLAIM-ROLL-SUBMIT")
        claim.save!
        @created_claim_ids << claim.id

        Corvid.configure do |c|
          c.on_provenance = ->(**attrs) { provenance_calls << attrs[:target_id] }
        end

        ActiveRecord::Base.transaction do
          claim.submit!
          raise ActiveRecord::Rollback
        end

        assert_equal "draft", claim.reload.status
        assert_empty provenance_calls,
          "expected on_provenance not to run for rolled-back submit!, got #{provenance_calls.inspect}"
      end
    end
  end

  test "claim submit! calls on_provenance once after outer transaction commits" do
    provenance_calls = []

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at(FACILITY, "REF-CLAIM-COMMIT-SUBMIT")
        authorize_referral!(referral)
        claim = build_claim(referral, "REF-CLAIM-COMMIT-SUBMIT")
        claim.save!
        @created_claim_ids << claim.id

        Corvid.configure do |c|
          c.on_provenance = ->(**attrs) { provenance_calls << attrs[:target_id] }
        end

        ActiveRecord::Base.transaction do
          claim.submit!
        end

        assert_equal "submitted", claim.reload.status
        assert_equal [ claim.id.to_s ], provenance_calls
      end
    end
  end

  test "claim mark_submitted! does not call on_provenance when outer transaction rolls back" do
    provenance_calls = []

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at(FACILITY, "REF-CLAIM-ROLL-MARK")
        authorize_referral!(referral)
        claim = build_claim(referral, "REF-CLAIM-ROLL-MARK")
        claim.save!
        @created_claim_ids << claim.id

        Corvid.configure do |c|
          c.on_provenance = ->(**attrs) { provenance_calls << attrs[:target_id] }
        end

        ActiveRecord::Base.transaction do
          claim.mark_submitted!(claim_identifier: "CLM-ROLL-MARK-1")
          raise ActiveRecord::Rollback
        end

        assert_equal "draft", claim.reload.status
        assert_empty provenance_calls,
          "expected on_provenance not to run for rolled-back mark_submitted!, got #{provenance_calls.inspect}"
      end
    end
  end

  test "claim mark_submitted! calls on_provenance once after outer transaction commits" do
    provenance_calls = []

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at(FACILITY, "REF-CLAIM-COMMIT-MARK")
        authorize_referral!(referral)
        claim = build_claim(referral, "REF-CLAIM-COMMIT-MARK")
        claim.save!
        @created_claim_ids << claim.id

        Corvid.configure do |c|
          c.on_provenance = ->(**attrs) { provenance_calls << attrs[:target_id] }
        end

        ActiveRecord::Base.transaction do
          claim.mark_submitted!(claim_identifier: "CLM-COMMIT-MARK-1")
        end

        assert_equal "submitted", claim.reload.status
        assert_equal [ claim.id.to_s ], provenance_calls
      end
    end
  end

  test "on_provenance database failure still syncs authorized CHS status after authorize!" do
    updates = []

    with_tenant(TENANT) do
      referral = authorized_referral_ready_to_authorize!
      Corvid.adapter.define_singleton_method(:update_referral) do |identifier, params|
        updates << [ identifier, params.dup ]
        true
      end
      configure_db_failing_provenance!

      logged = []
      Rails.logger.stub(:error, ->(msg) { logged << msg }) do
        assert referral.authorize!
      end
      assert referral.reload.authorized?
      authorized_syncs = updates.select { |(_, params)| params[:chs_approval_status] == "A" }
      assert_equal 1, authorized_syncs.size,
        "expected exactly one authorized CHS sync, got #{updates.inspect}"
      assert_equal referral.referral_identifier, authorized_syncs.first.first
      assert logged.any? { |m| m.to_s.include?("Provenance hook failed") }
    end
  end

  private

  def configure_db_failing_provenance!
    Corvid.configure { |c| c.on_provenance = db_failing_provenance_hook }
  end

  def db_failing_provenance_hook
    ->(**_attrs) { ActiveRecord::Base.connection.execute("SELECT 1/0") }
  end

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: PATIENT,
      facility_identifier: facility
    )
    referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: facility
    )
    @created_referral_ids << referral.id
    referral
  end

  def delete_created_fixture_rows!
    claim_ids = @created_claim_ids
    Corvid::ClaimSubmission.unscoped.where(id: claim_ids).delete_all if claim_ids.present?

    ids = @created_referral_ids
    return if ids.blank?

    Corvid::CommitteeReview.unscoped.where(prc_referral_id: ids).delete_all
    Corvid::AlternateResourceCheck.unscoped.where(prc_referral_id: ids).delete_all
    Corvid::EligibilityChecklist.unscoped.where(prc_referral_id: ids).delete_all
    case_ids = Corvid::PrcReferral.unscoped.where(id: ids).pluck(:case_id)
    Corvid::PrcReferral.unscoped.where(id: ids).delete_all
    Corvid::Case.unscoped.where(id: case_ids).delete_all
    @created_referral_ids = []
  end

  def referral_ready_for_priority_completion!
    referral = referral_at(FACILITY, "REF-PROV-COMPLETE")
    referral.submit!
    referral.begin_eligibility_review!
    checklist = referral.eligibility_checklist
    Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
      fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
      kwargs = {}
      kwargs[:source] = "test_fixture" if fields.key?(:source)
      kwargs[:by] = "usr_submitter" if fields.key?(:by)
      checklist.verify_item!(item, **kwargs)
    end
    referral.reload
    referral.request_management_approval!
    referral.pending_approval_by = "usr_other"
    referral.approve_management!
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.reload
  end

  def committee_ready_referral!
    referral = referral_at(FACILITY, "REF-PROV-COMMITTEE")
    referral.submit!
    referral.begin_eligibility_review!
    checklist = referral.eligibility_checklist
    Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
      fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
      kwargs = {}
      kwargs[:source] = "test_fixture" if fields.key?(:source)
      kwargs[:by] = "usr_submitter" if fields.key?(:by)
      checklist.verify_item!(item, **kwargs)
    end
    referral.reload
    referral.request_management_approval!
    referral.pending_approval_by = "usr_other"
    referral.approve_management!
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.update!(medical_priority: 3, estimated_cost: 5_000)
    referral.complete_priority_assignment!
    assert_equal "committee_review", referral.status
    exhaust_alternate_resources!(referral, date_of_service: Date.current, as_of: Time.current)
    referral.reload
  end

  def build_claim(referral, referral_identifier)
    Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT,
      facility_identifier: FACILITY,
      patient_identifier: referral.case.patient_identifier,
      referral_identifier: referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2025, 6, 10),
      billed_amount: 100.0,
      status: "draft"
    )
  end

  def authorize_referral!(referral)
    referral.submit!
    referral.begin_eligibility_review!
    checklist = referral.eligibility_checklist
    Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
      fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
      kwargs = {}
      kwargs[:source] = "test_fixture" if fields.key?(:source)
      kwargs[:by] = "usr_submitter" if fields.key?(:by)
      checklist.verify_item!(item, **kwargs)
    end
    referral.reload
    referral.request_management_approval!
    referral.pending_approval_by = "usr_other"
    referral.approve_management!
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.complete_priority_assignment!
    referral.authorize! if referral.may_authorize?
    referral.reload
  end

  def authorized_referral_ready_to_authorize!
    referral = referral_at(FACILITY, "REF-PROV-AUTH")
    referral.submit!
    referral.begin_eligibility_review!
    checklist = referral.eligibility_checklist
    Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
      fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
      kwargs = {}
      kwargs[:source] = "test_fixture" if fields.key?(:source)
      kwargs[:by] = "usr_submitter" if fields.key?(:by)
      checklist.verify_item!(item, **kwargs)
    end
    referral.reload
    referral.request_management_approval!
    referral.pending_approval_by = "usr_other"
    referral.approve_management!
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.complete_priority_assignment!
    referral.update_column(:status, "priority_assignment")
    referral.reload
  end
end
