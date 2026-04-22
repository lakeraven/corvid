# frozen_string_literal: true

require "test_helper"

class Corvid::AlternateResourceCheckTest < ActiveSupport::TestCase
  TENANT = "tnt_arc_test"

  setup do
    Corvid::AlternateResourceCheck.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # -- Validation -------------------------------------------------------------

  test "valid with required fields" do
    with_tenant(TENANT) do
      check = build_check(resource_type: "medicare_a")
      assert check.valid?
    end
  end

  test "requires valid resource_type" do
    with_tenant(TENANT) do
      check = build_check(resource_type: "invalid_type")
      refute check.valid?
    end
  end

  test "resource_type unique per referral" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a")
      dup = Corvid::AlternateResourceCheck.new(prc_referral: referral, resource_type: "medicare_a")
      refute dup.valid?
    end
  end

  # -- Status -----------------------------------------------------------------

  test "defaults to not_checked" do
    with_tenant(TENANT) do
      check = build_check
      assert_equal "not_checked", check.status
    end
  end

  test "verify! transitions to enrolled or not_enrolled" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral, resource_type: "medicare_a"
      )
      check.verify!
      assert %w[enrolled not_enrolled].include?(check.status)
    end
  end

  # -- Scopes -----------------------------------------------------------------

  test "active_coverage scope" do
    with_tenant(TENANT) do
      referral = create_referral
      enrolled = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "enrolled"
      )
      not_enrolled = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_b", status: "not_enrolled"
      )

      assert_includes Corvid::AlternateResourceCheck.active_coverage, enrolled
      refute_includes Corvid::AlternateResourceCheck.active_coverage, not_enrolled
    end
  end

  test "unavailable scope" do
    with_tenant(TENANT) do
      referral = create_referral
      denied = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "denied"
      )
      enrolled = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "enrolled"
      )

      assert_includes Corvid::AlternateResourceCheck.unavailable, denied
      refute_includes Corvid::AlternateResourceCheck.unavailable, enrolled
    end
  end

  # -- Class methods ----------------------------------------------------------

  test "all_exhausted? when all checks are unavailable" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "not_enrolled"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "denied"
      )

      assert Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  test "any_pending? when checks still pending" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "not_checked"
      )

      assert Corvid::AlternateResourceCheck.any_pending?(referral)
    end
  end

  # -- Coordination -----------------------------------------------------------

  test "requires_coordination? for enrolled federal resources" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral, resource_type: "medicare_a", status: "enrolled"
      )
      assert check.requires_coordination?
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: "pt_arc_test",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_referral
    Corvid::PrcReferral.create!(case: create_case, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def build_check(resource_type: "medicare_a")
    Corvid::AlternateResourceCheck.new(
      prc_referral: create_referral,
      resource_type: resource_type
    )
  end
end
