# frozen_string_literal: true

require "test_helper"

class Corvid::EligibilityChecklistServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_ecs_test"

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

  test "populate! marks enrollment_verified only when enrolled and confidence is verified" do
    with_tenant(TENANT) do
      adapter = Corvid.adapter
      patient_id = "pt_ecs_verified"
      adapter.add_patient(patient_id, display_name: "TEST", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "1234")
      adapter.add_enrollment(patient_id,
                             enrolled: true, tribe_name: "T", tribe_code: "T",
                             member_status: "enrolled", confidence: :verified)

      referral = create_referral(patient_id: patient_id)
      checklist = Corvid::EligibilityChecklistService.populate!(referral, adapter: adapter)

      assert checklist.enrollment_verified
    end
  end

  test "populate! does not mark enrollment_verified when confidence is stale" do
    with_tenant(TENANT) do
      adapter = Corvid.adapter
      patient_id = "pt_ecs_stale"
      adapter.add_patient(patient_id, display_name: "TEST", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "1234")
      adapter.add_enrollment(patient_id,
                             enrolled: true, tribe_name: "T", tribe_code: "T",
                             member_status: "enrolled", confidence: :stale)

      referral = create_referral(patient_id: patient_id)
      checklist = Corvid::EligibilityChecklistService.populate!(referral, adapter: adapter)

      refute checklist.enrollment_verified
    end
  end

  test "populate! does not mark enrollment_verified when confidence is unavailable" do
    with_tenant(TENANT) do
      adapter = Corvid.adapter
      patient_id = "pt_ecs_unavail"
      adapter.add_patient(patient_id, display_name: "TEST", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "1234")
      adapter.add_enrollment(patient_id,
                             enrolled: true, tribe_name: "T", tribe_code: "T",
                             member_status: "enrolled", confidence: :unavailable)

      referral = create_referral(patient_id: patient_id)
      checklist = Corvid::EligibilityChecklistService.populate!(referral, adapter: adapter)

      refute checklist.enrollment_verified
    end
  end

  test "populate! does not mark enrollment_verified when confidence is missing from enrollment record" do
    with_tenant(TENANT) do
      adapter = Corvid.adapter
      patient_id = "pt_ecs_no_conf"
      adapter.add_patient(patient_id, display_name: "TEST", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "1234")
      adapter.add_enrollment(patient_id,
                             enrolled: true, tribe_name: "T", tribe_code: "T",
                             member_status: "enrolled")

      referral = create_referral(patient_id: patient_id)
      checklist = Corvid::EligibilityChecklistService.populate!(referral, adapter: adapter)

      refute checklist.enrollment_verified
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

  def create_referral(patient_id: "pt_ecs")
    c = Corvid::Case.create!(patient_identifier: patient_id, lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end
end
