# frozen_string_literal: true

require "test_helper"

class Corvid::PriorAuthorizationServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_pa_test"

  setup do
    Corvid::AlternateResourceCheck.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # REQUIRED?
  # =============================================================================

  test "required? returns true for high-cost referral" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 60_000)
      assert Corvid::PriorAuthorizationService.required?(referral)
    end
  end

  test "required? returns false for low-cost referral" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 10_000)
      refute Corvid::PriorAuthorizationService.required?(referral)
    end
  end

  test "required? returns true for priority 3 or higher" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 1_000, medical_priority: 3)
      assert Corvid::PriorAuthorizationService.required?(referral)
    end
  end

  test "required? returns true when flagged_for_review" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 1_000, flagged_for_review: true)
      assert Corvid::PriorAuthorizationService.required?(referral)
    end
  end

  # =============================================================================
  # AUTO_AUTHORIZABLE?
  # =============================================================================

  test "auto_authorizable? true when not required and resources exhausted" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 1_000)
      # Create all resource checks as unavailable
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicare_a",
        status: :not_enrolled
      )

      assert Corvid::PriorAuthorizationService.auto_authorizable?(referral)
    end
  end

  test "auto_authorizable? false when committee review required" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 60_000)
      refute Corvid::PriorAuthorizationService.auto_authorizable?(referral)
    end
  end

  test "auto_authorizable? false when resources still pending" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 1_000)
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicare_a",
        status: :not_checked
      )

      refute Corvid::PriorAuthorizationService.auto_authorizable?(referral)
    end
  end

  # =============================================================================
  # EMERGENCY HANDLING
  # =============================================================================

  test "emergency referral within 72 hours is compliant" do
    with_tenant(TENANT) do
      referral = create_referral(
        emergency_flag: true,
        notification_date: 24.hours.ago
      )
      assert_equal "timely", referral.notification_status
    end
  end

  test "emergency referral beyond 72 hours needs exception review" do
    with_tenant(TENANT) do
      referral = create_referral(
        emergency_flag: true,
        notification_date: 80.hours.ago
      )
      assert_equal "late", referral.notification_status
      assert referral.requires_exception_review?
    end
  end

  test "non-emergency referral does not require notification" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: false)
      assert_equal "not_required", referral.notification_status
      refute referral.requires_exception_review?
    end
  end

  test "emergency referral with no notification date is missing" do
    with_tenant(TENANT) do
      referral = create_referral(
        emergency_flag: true,
        notification_date: nil
      )
      assert_equal "missing", referral.notification_status
      assert referral.requires_exception_review?
    end
  end

  private

  def create_referral(**attrs)
    c = Corvid::Case.create!(
      patient_identifier: "pt_pa_test",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
    Corvid::PrcReferral.create!(
      case: c,
      referral_identifier: "ref_#{SecureRandom.hex(4)}",
      **attrs
    )
  end
end
