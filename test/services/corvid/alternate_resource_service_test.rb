# frozen_string_literal: true

require "test_helper"

class Corvid::AlternateResourceServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_ars_test"

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
      create_all_twelve_unavailable_checks(referral)

      assert Corvid::AlternateResourceService.all_exhausted?(referral)
    end
  end

  test "all_exhausted? false when referral has no alternate resource checks" do
    with_tenant(TENANT) do
      referral = create_referral

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "all_exhausted? false when only a partial set of resource types is unavailable" do
    with_tenant(TENANT) do
      referral = create_referral
      %w[medicare_a medicaid private_insurance charity_care].each do |type|
        Corvid::AlternateResourceCheck.create!(
          prc_referral: referral, resource_type: type, status: "not_enrolled"
        )
      end

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "all_exhausted? true when all twelve resource types are positively unavailable" do
    with_tenant(TENANT) do
      referral = create_referral
      create_all_twelve_unavailable_checks(
        referral,
        "medicare_a" => "not_enrolled",
        "medicaid" => "denied",
        "private_insurance" => "exhausted"
      )

      assert Corvid::AlternateResourceService.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "all_exhausted? false when all twelve rows exist but one is not_checked" do
    with_tenant(TENANT) do
      referral = create_referral
      create_all_twelve_unavailable_checks(referral, "tribal_program" => "not_checked")

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "all_exhausted? false when all twelve rows exist but one is checking" do
    with_tenant(TENANT) do
      referral = create_referral
      create_all_twelve_unavailable_checks(referral, "workers_comp" => "checking")

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "all_exhausted? false when all twelve rows exist but one is pending_enrollment" do
    with_tenant(TENANT) do
      referral = create_referral
      create_all_twelve_unavailable_checks(referral, "state_program" => "pending_enrollment")

      refute Corvid::AlternateResourceService.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
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

  test "has_active_coverage? true when the only covering check is coordinated" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "coordinated"
      )

      assert Corvid::AlternateResourceService.has_active_coverage?(referral)
    end
  end

  test "verify_all with unreachable adapter leaves all checks not_checked" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_patient_identifier, _resource_type|
        { error: "unreachable" }
      end

      Corvid::AlternateResourceService.verify_all(referral)
      checks = referral.alternate_resource_checks.reload

      assert_equal Corvid::AlternateResourceCheck::RESOURCE_TYPES.size, checks.count
      assert_equal checks.count, checks.where(status: "not_checked").count
      assert_equal 0, checks.where(status: "not_enrolled").count
      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_ars", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_all_twelve_unavailable_checks(referral, status_overrides = {})
    Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
      status = status_overrides.fetch(type, "not_enrolled")
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: type,
        status: status
      )
      stamp_alternate_resource_check_current!(check) unless %w[not_checked checking].include?(status)
    end
  end

  def assert_exhaustion_agreement(referral)
    service = Corvid::AlternateResourceService.all_exhausted?(referral)
    model = Corvid::AlternateResourceCheck.all_exhausted?(referral)
    assert_equal service, model, "AlternateResourceService and AlternateResourceCheck must agree"
  end
end
