# frozen_string_literal: true

require "test_helper"

class Corvid::EligibilityChecklistTest < ActiveSupport::TestCase
  TEST_TENANT = "tnt_test"

  setup do
    with_tenant(TEST_TENANT) do
      @case = Corvid::Case.create!(patient_identifier: "pt_test_001")
      @referral = Corvid::PrcReferral.create!(
        case: @case,
        referral_identifier: "rf_checklist_test_001"
      )
    end
  end

  test "table is corvid_eligibility_checklists" do
    assert_equal "corvid_eligibility_checklists", Corvid::EligibilityChecklist.table_name
  end

  test "belongs to prc_referral" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      assert_equal @referral, checklist.prc_referral
    end
  end

  test "prc_referral has_one eligibility_checklist" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      assert_equal checklist, @referral.reload.eligibility_checklist
    end
  end

  test "new checklist starts with all items incomplete" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      refute checklist.application_complete
      refute checklist.identity_verified
      refute checklist.insurance_verified
      refute checklist.residency_verified
      refute checklist.enrollment_verified
      refute checklist.clinical_necessity_documented
      refute checklist.management_approved
    end
  end

  test "complete? returns false when any item is missing" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      refute checklist.complete?
    end
  end

  test "complete? returns true when all 7 items are true" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      checklist.update!(
        application_complete: true,
        identity_verified: true,
        insurance_verified: true,
        residency_verified: true,
        enrollment_verified: true,
        clinical_necessity_documented: true,
        management_approved: true
      )
      assert checklist.complete?
    end
  end

  test "missing_items returns symbols of incomplete items" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      expected = %i[
        application_complete identity_verified insurance_verified
        residency_verified enrollment_verified clinical_necessity_documented
        management_approved
      ]
      assert_equal expected.sort, checklist.missing_items.sort
    end
  end

  test "missing_items returns empty array when all complete" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(
        prc_referral: @referral,
        application_complete: true,
        identity_verified: true,
        insurance_verified: true,
        residency_verified: true,
        enrollment_verified: true,
        clinical_necessity_documented: true,
        management_approved: true
      )
      assert_empty checklist.missing_items
    end
  end

  test "compliance_percentage returns ratio of complete items" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      assert_in_delta 0.0, checklist.compliance_percentage, 0.01

      checklist.update!(
        application_complete: true,
        identity_verified: true,
        enrollment_verified: true
      )
      assert_in_delta 42.86, checklist.compliance_percentage, 0.01

      checklist.update!(
        insurance_verified: true,
        residency_verified: true,
        clinical_necessity_documented: true,
        management_approved: true
      )
      assert_in_delta 100.0, checklist.compliance_percentage, 0.01
    end
  end

  test "verify_item! sets boolean, timestamp, and source" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      checklist.verify_item!(:enrollment_verified, source: "baseroll")

      assert checklist.enrollment_verified
      assert_not_nil checklist.enrollment_verified_at
      assert_equal "baseroll", checklist.enrollment_verification_source
    end
  end

  test "verify_item! sets by field for items that track approver" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      checklist.verify_item!(:application_complete, source: "manual", by: "pr_mgr_001")

      assert checklist.application_complete
      assert_not_nil checklist.application_completed_at
      assert_equal "pr_mgr_001", checklist.application_completed_by
    end
  end

  test "verify_item! for management_approved records approver" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      checklist.verify_item!(:management_approved, source: "manual", by: "pr_mgr_001")

      assert checklist.management_approved
      assert_not_nil checklist.management_approved_at
      assert_equal "pr_mgr_001", checklist.management_approved_by
    end
  end

  test "items_except_approval_complete? returns true when 6 of 7 done" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(
        prc_referral: @referral,
        application_complete: true,
        identity_verified: true,
        insurance_verified: true,
        residency_verified: true,
        enrollment_verified: true,
        clinical_necessity_documented: true,
        management_approved: false
      )
      assert checklist.items_except_approval_complete?
    end
  end

  test "items_except_approval_complete? returns false when non-approval item missing" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(
        prc_referral: @referral,
        application_complete: true,
        identity_verified: false,
        insurance_verified: true,
        residency_verified: true,
        enrollment_verified: true,
        clinical_necessity_documented: true,
        management_approved: false
      )
      refute checklist.items_except_approval_complete?
    end
  end

  test "auto-assigns tenant_identifier from context" do
    with_tenant(TEST_TENANT) do
      checklist = Corvid::EligibilityChecklist.create!(prc_referral: @referral)
      assert_equal TEST_TENANT, checklist.tenant_identifier
    end
  end
end
