# frozen_string_literal: true

require "test_helper"

class Corvid::AlternateResourceCheckTest < ActiveSupport::TestCase
  TENANT = "tnt_arc_test"

  setup do
    Corvid::AlternateResourceCheck.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # RESOURCE_TYPES CONSTANT
  # =============================================================================

  test "RESOURCE_TYPES includes all 12 payer types per 42 CFR 136.61" do
    expected = %w[
      medicare_a medicare_b medicare_d medicaid va_benefits
      private_insurance workers_comp auto_insurance liability_coverage
      state_program tribal_program charity_care
    ]
    assert_equal expected.sort, Corvid::AlternateResourceCheck::RESOURCE_TYPES.sort
  end

  test "FEDERAL_TYPES includes federal payers" do
    assert_includes Corvid::AlternateResourceCheck::FEDERAL_TYPES, "medicare_a"
    assert_includes Corvid::AlternateResourceCheck::FEDERAL_TYPES, "medicaid"
    assert_includes Corvid::AlternateResourceCheck::FEDERAL_TYPES, "va_benefits"
  end

  test "PRIVATE_TYPES includes private payers" do
    assert_includes Corvid::AlternateResourceCheck::PRIVATE_TYPES, "private_insurance"
    assert_includes Corvid::AlternateResourceCheck::PRIVATE_TYPES, "workers_comp"
    assert_includes Corvid::AlternateResourceCheck::PRIVATE_TYPES, "auto_insurance"
  end

  # =============================================================================
  # VALIDATIONS
  # =============================================================================

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

  test "resource_type must be unique per referral" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a")
      dup = Corvid::AlternateResourceCheck.new(prc_referral: referral, resource_type: "medicare_a")
      refute dup.valid?
    end
  end

  test "same resource_type can exist for different referrals" do
    with_tenant(TENANT) do
      r1 = create_referral
      r2 = create_referral
      c1 = Corvid::AlternateResourceCheck.create!(prc_referral: r1, resource_type: "medicare_a")
      c2 = Corvid::AlternateResourceCheck.create!(prc_referral: r2, resource_type: "medicare_a")
      assert c1.persisted?
      assert c2.persisted?
    end
  end

  test "accepts all valid resource types" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        check = Corvid::AlternateResourceCheck.create!(
          prc_referral: referral,
          resource_type: type
        )
        assert check.persisted?, "Failed for type: #{type}"
      end
    end
  end

  # =============================================================================
  # STATUS ENUM
  # =============================================================================

  test "defaults to not_checked status" do
    with_tenant(TENANT) do
      check = build_check
      assert_equal "not_checked", check.status
    end
  end

  test "can transition to checking" do
    with_tenant(TENANT) do
      check = create_check
      check.checking!
      assert check.checking?
    end
  end

  test "can transition to enrolled" do
    with_tenant(TENANT) do
      check = create_check
      check.enrolled!
      assert check.enrolled?
    end
  end

  test "can transition to not_enrolled" do
    with_tenant(TENANT) do
      check = create_check
      check.not_enrolled!
      assert check.not_enrolled?
    end
  end

  test "can transition to denied" do
    with_tenant(TENANT) do
      check = create_check
      check.denied!
      assert check.denied?
    end
  end

  test "can transition to exhausted" do
    with_tenant(TENANT) do
      check = create_check
      check.exhausted!
      assert check.exhausted?
    end
  end

  test "can transition to pending_enrollment" do
    with_tenant(TENANT) do
      check = create_check
      check.pending_enrollment!
      assert check.pending_enrollment?
    end
  end

  test "verify! transitions to enrolled or not_enrolled" do
    with_tenant(TENANT) do
      check = create_check
      check.verify!
      assert %w[enrolled not_enrolled].include?(check.status)
    end
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "active_coverage returns enrolled and pending_enrollment" do
    with_tenant(TENANT) do
      referral = create_referral
      enrolled = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a", status: :enrolled)
      pending = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_b", status: :pending_enrollment)
      not_enrolled = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicaid", status: :not_enrolled)

      active = Corvid::AlternateResourceCheck.active_coverage
      assert_includes active, enrolled
      assert_includes active, pending
      refute_includes active, not_enrolled
    end
  end

  test "unavailable returns not_enrolled, denied, exhausted" do
    with_tenant(TENANT) do
      referral = create_referral
      not_enrolled = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a", status: :not_enrolled)
      denied_check = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_b", status: :denied)
      exhausted_check = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicaid", status: :exhausted)
      enrolled = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "va_benefits", status: :enrolled)

      unavailable = Corvid::AlternateResourceCheck.unavailable
      assert_includes unavailable, not_enrolled
      assert_includes unavailable, denied_check
      assert_includes unavailable, exhausted_check
      refute_includes unavailable, enrolled
    end
  end

  test "pending scope returns not_checked, checking, pending_enrollment" do
    with_tenant(TENANT) do
      referral = create_referral
      nc = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a", status: :not_checked)
      checking = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_b", status: :checking)
      pe = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicaid", status: :pending_enrollment)
      enrolled = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "va_benefits", status: :enrolled)

      pending_checks = Corvid::AlternateResourceCheck.pending
      assert_includes pending_checks, nc
      assert_includes pending_checks, checking
      assert_includes pending_checks, pe
      refute_includes pending_checks, enrolled
    end
  end

  test "federal scope returns federal types" do
    with_tenant(TENANT) do
      referral = create_referral
      medicare = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a")
      private_ins = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "private_insurance")

      federal = Corvid::AlternateResourceCheck.federal
      assert_includes federal, medicare
      refute_includes federal, private_ins
    end
  end

  test "private_payer scope returns private types" do
    with_tenant(TENANT) do
      referral = create_referral
      private_ins = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "private_insurance")
      medicare = Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a")

      private_checks = Corvid::AlternateResourceCheck.private_payer
      assert_includes private_checks, private_ins
      refute_includes private_checks, medicare
    end
  end

  # =============================================================================
  # CLASS METHODS
  # =============================================================================

  test "all_exhausted? returns true when no active coverage and no pending" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a", status: :not_enrolled)
      Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicaid", status: :denied)
      assert Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  test "all_exhausted? returns false when some pending" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a", status: :not_checked)
      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  test "all_exhausted? returns false when some enrolled" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a", status: :enrolled)
      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  test "any_pending? returns true when pending checks exist" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a", status: :not_checked)
      assert Corvid::AlternateResourceCheck.any_pending?(referral)
    end
  end

  test "any_pending? returns false when no pending" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(prc_referral: referral, resource_type: "medicare_a", status: :enrolled)
      refute Corvid::AlternateResourceCheck.any_pending?(referral)
    end
  end

  test "create_all_for_referral creates all 12 types" do
    with_tenant(TENANT) do
      referral = create_referral
      checks = Corvid::AlternateResourceCheck.create_all_for_referral(referral)
      assert_equal 12, checks.length
      assert_equal Corvid::AlternateResourceCheck::RESOURCE_TYPES.sort,
                   checks.map(&:resource_type).sort
    end
  end

  # =============================================================================
  # INSTANCE METHODS
  # =============================================================================

  test "requires_coordination? true when enrolled" do
    with_tenant(TENANT) do
      check = create_check(status: :enrolled)
      assert check.requires_coordination?
    end
  end

  test "requires_coordination? false when not enrolled" do
    with_tenant(TENANT) do
      check = create_check(status: :not_enrolled)
      refute check.requires_coordination?
    end
  end

  test "resource_name returns human-readable name" do
    check = Corvid::AlternateResourceCheck.new(resource_type: "medicare_a")
    assert_equal "Medicare Part A", check.resource_name
  end

  test "resource_name for all types returns non-blank" do
    Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
      check = Corvid::AlternateResourceCheck.new(resource_type: type)
      assert check.resource_name.present?, "Missing name for #{type}"
    end
  end

  test "stale? returns true when checked_at is nil" do
    check = Corvid::AlternateResourceCheck.new
    assert check.stale?
  end

  test "stale? returns true when older than max_age" do
    check = Corvid::AlternateResourceCheck.new(checked_at: 31.days.ago)
    assert check.stale?
  end

  test "stale? returns false when within max_age" do
    check = Corvid::AlternateResourceCheck.new(checked_at: 1.day.ago)
    refute check.stale?
  end

  # =============================================================================
  # CALLBACKS
  # =============================================================================

  test "sets checked_at when status changes from not_checked" do
    with_tenant(TENANT) do
      check = create_check
      assert_nil check.checked_at
      check.enrolled!
      assert_not_nil check.checked_at
    end
  end

  # =============================================================================
  # COVERAGE DATES
  # =============================================================================

  test "stores coverage_start and coverage_end" do
    with_tenant(TENANT) do
      check = create_check
      check.update!(
        coverage_start: Date.new(2024, 1, 1),
        coverage_end: Date.new(2024, 12, 31),
        status: :enrolled
      )
      check.reload
      assert_equal Date.new(2024, 1, 1), check.coverage_start
      assert_equal Date.new(2024, 12, 31), check.coverage_end
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

  def create_check(resource_type: "medicare_a", **attrs)
    Corvid::AlternateResourceCheck.create!(
      prc_referral: attrs.delete(:prc_referral) || create_referral,
      resource_type: resource_type,
      **attrs
    )
  end
end
