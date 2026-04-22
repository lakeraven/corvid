# frozen_string_literal: true

require "test_helper"

class Corvid::AlternateResourceServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_ars_test"

  setup do
    Corvid::AlternateResourceCheck.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  test "verify_all creates checks for all resource types" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceService.verify_all(referral)

      assert referral.alternate_resource_checks.any?
    end
  end

  test "all_exhausted? true when all checks unavailable" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "not_enrolled"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "denied"
      )

      assert Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  test "all_exhausted? false when some checks active" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "enrolled"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "not_enrolled"
      )

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  test "has_active_coverage? true when enrolled check exists" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "enrolled"
      )

      assert Corvid::AlternateResourceService.has_active_coverage?(referral)
    end
  end

  test "has_active_coverage? false when no enrolled checks" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "not_enrolled"
      )

      refute Corvid::AlternateResourceService.has_active_coverage?(referral)
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_ars", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end
end
