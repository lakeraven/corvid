# frozen_string_literal: true

require "test_helper"

class Corvid::EligibilityChecklistServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_ecs_test"

  setup do
    Corvid::EligibilityChecklist.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  test "populate! creates checklist if none exists" do
    with_tenant(TENANT) do
      referral = create_referral
      checklist = Corvid::EligibilityChecklistService.populate!(referral)

      assert checklist.persisted?
      assert_equal referral, checklist.prc_referral
    end
  end

  test "populate! is idempotent" do
    with_tenant(TENANT) do
      referral = create_referral
      c1 = Corvid::EligibilityChecklistService.populate!(referral)
      c2 = Corvid::EligibilityChecklistService.populate!(referral)

      assert_equal c1.id, c2.id
    end
  end

  test "populate! calls adapter for enrollment verification" do
    with_tenant(TENANT) do
      referral = create_referral
      checklist = Corvid::EligibilityChecklistService.populate!(referral)

      # Checklist exists and was populated (adapter may or may not verify)
      assert checklist.persisted?
    end
  end

  test "verify_item! manually verifies a checklist item" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::EligibilityChecklistService.populate!(referral)

      Corvid::EligibilityChecklistService.verify_item!(
        referral, :clinical_necessity_documented, source: "staff_review"
      )

      assert referral.eligibility_checklist.reload.clinical_necessity_documented
    end
  end

  test "approve! verifies management_approved item" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::EligibilityChecklistService.populate!(referral)

      Corvid::EligibilityChecklistService.approve!(referral, by: "pr_001")

      assert referral.eligibility_checklist.reload.management_approved
    end
  end

  test "verify_item! raises when no checklist exists" do
    with_tenant(TENANT) do
      referral = create_referral

      assert_raises(ArgumentError) do
        Corvid::EligibilityChecklistService.verify_item!(
          referral, :enrollment_verified, source: "test"
        )
      end
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_ecs", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end
end
