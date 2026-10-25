# frozen_string_literal: true

require "test_helper"

class Corvid::EligibilityChecklistIdentifiersTest < ActiveSupport::TestCase
  TEST_TENANT = "tnt_checklist_identifiers"

  setup do
    with_tenant(TEST_TENANT) do
      @case = Corvid::Case.create!(patient_identifier: "pt_chk_id_001")
      @referral = Corvid::PrcReferral.create!(
        case: @case,
        referral_identifier: "rf_chk_id_001"
      )
      @checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
    end
  end

  test "ITEM_FIELDS maps approver metadata to *_by_identifier columns" do
    fields = Corvid::EligibilityChecklist::ITEM_FIELDS
    assert_equal :application_completed_by_identifier, fields.fetch(:application_complete)[:by]
    assert_equal :management_approved_by_identifier, fields.fetch(:management_approved)[:by]
  end

  test "verify_item! application_complete stores application_completed_by_identifier" do
    with_tenant(TEST_TENANT) do
      @checklist.verify_item!(:application_complete, by: "pr_test_001")

      assert_equal "pr_test_001", @checklist.reload.application_completed_by_identifier
    end
  end

  test "approve! via EligibilityChecklistService stores management_approved_by_identifier" do
    with_tenant(TEST_TENANT) do
      Corvid::EligibilityChecklistService.approve!(@referral, by: "pr_mgr_svc_001")

      assert_equal "pr_mgr_svc_001", @referral.eligibility_checklist.reload.management_approved_by_identifier
    end
  end

  test "clear_management_approval! clears management_approved_by_identifier" do
    with_tenant(TEST_TENANT) do
      @checklist.verify_item!(:management_approved, by: "pr_mgr_clear_001")
      @checklist.clear_management_approval!

      checklist = @checklist.reload
      refute checklist.management_approved
      assert_nil checklist.management_approved_at
      assert_nil checklist.management_approved_by_identifier
    end
  end

  test "unverify_item! clears application_completed_by_identifier" do
    with_tenant(TEST_TENANT) do
      @checklist.verify_item!(:application_complete, by: "pr_test_002")
      @checklist.unverify_item!(:application_complete)

      checklist = @checklist.reload
      refute checklist.application_complete
      assert_nil checklist.application_completed_at
      assert_nil checklist.application_completed_by_identifier
    end
  end

  test "legacy *_by attribute names are removed" do
    with_tenant(TEST_TENANT) do
      refute @checklist.respond_to?(:management_approved_by)
      refute @checklist.respond_to?(:application_completed_by)

      assert_raises(ActiveModel::UnknownAttributeError) do
        @checklist.update!(management_approved_by: "pr_legacy")
      end
    end
  end

  test "interim *_identifier column names are not exposed" do
    with_tenant(TEST_TENANT) do
      refute @checklist.respond_to?(:management_approved_identifier)
      refute @checklist.respond_to?(:application_completed_identifier)
    end
  end
end
