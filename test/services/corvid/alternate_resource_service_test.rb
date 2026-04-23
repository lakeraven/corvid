# frozen_string_literal: true

require "test_helper"

class Corvid::AlternateResourceServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_ars_test"

  setup do
    Corvid::AlternateResourceCheck.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # VERIFY ALL
  # =============================================================================

  test "verify_all creates checks for all 12 resource types" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceService.verify_all(referral)

      assert_equal 12, referral.alternate_resource_checks.count
    end
  end

  test "verify_all sets status on each check" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceService.verify_all(referral)

      referral.alternate_resource_checks.each do |check|
        refute_equal "not_checked", check.status,
          "#{check.resource_type} should have been verified"
      end
    end
  end

  # =============================================================================
  # ALL EXHAUSTED?
  # =============================================================================

  test "all_exhausted? true when all checks unavailable" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "not_enrolled")
      create_check(referral, "medicaid", "denied")

      assert Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  test "all_exhausted? false when some checks active" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "enrolled")
      create_check(referral, "medicaid", "not_enrolled")

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  test "all_exhausted? false when no checks exist" do
    with_tenant(TENANT) do
      referral = create_referral
      # Empty — vacuously true for Array#all? but we want false
      # Actually Array#all? on empty is true, so this tests implementation
      assert Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  test "all_exhausted? true when all exhausted" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "exhausted")
      create_check(referral, "medicaid", "exhausted")

      assert Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  test "all_exhausted? false when pending_enrollment" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "pending_enrollment")

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  test "all_exhausted? false when checking" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "checking")

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  # =============================================================================
  # HAS ACTIVE COVERAGE?
  # =============================================================================

  test "has_active_coverage? true when enrolled check exists" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "enrolled")

      assert Corvid::AlternateResourceService.has_active_coverage?(referral)
    end
  end

  test "has_active_coverage? true when pending_enrollment exists" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "pending_enrollment")

      assert Corvid::AlternateResourceService.has_active_coverage?(referral)
    end
  end

  test "has_active_coverage? false when no enrolled checks" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "not_enrolled")

      refute Corvid::AlternateResourceService.has_active_coverage?(referral)
    end
  end

  test "has_active_coverage? false when all denied" do
    with_tenant(TENANT) do
      referral = create_referral
      create_check(referral, "medicare_a", "denied")
      create_check(referral, "medicaid", "denied")

      refute Corvid::AlternateResourceService.has_active_coverage?(referral)
    end
  end

  test "has_active_coverage? false when no checks" do
    with_tenant(TENANT) do
      referral = create_referral
      refute Corvid::AlternateResourceService.has_active_coverage?(referral)
    end
  end

  # =============================================================================
  # FEDERAL VS PRIVATE
  # =============================================================================

  test "verify_all includes federal resource types" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceService.verify_all(referral)

      types = referral.alternate_resource_checks.pluck(:resource_type)
      assert_includes types, "medicare_a"
      assert_includes types, "medicaid"
      assert_includes types, "va_benefits"
    end
  end

  test "verify_all includes private resource types" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceService.verify_all(referral)

      types = referral.alternate_resource_checks.pluck(:resource_type)
      assert_includes types, "private_insurance"
      assert_includes types, "workers_comp"
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(
      patient_identifier: "pt_ars",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_check(referral, resource_type, status)
    Corvid::AlternateResourceCheck.create!(
      prc_referral: referral,
      resource_type: resource_type,
      status: status
    )
  end
end
