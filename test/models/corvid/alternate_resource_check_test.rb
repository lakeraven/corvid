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

  test "requires_coordination? returns false for exhausted" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.new(status: :exhausted)
      refute check.requires_coordination?
    end
  end

  # -- requires resource_type ------------------------------------------------

  test "requires resource_type" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.new(prc_referral: create_referral, resource_type: nil)
      refute check.valid?
    end
  end

  # -- same resource_type different referrals --------------------------------

  test "same resource_type can exist for different referrals" do
    with_tenant(TENANT) do
      ref1 = create_referral
      ref2 = create_referral
      Corvid::AlternateResourceCheck.create!(prc_referral: ref1, resource_type: "medicare_a")
      check2 = Corvid::AlternateResourceCheck.new(prc_referral: ref2, resource_type: "medicare_a")
      assert check2.valid?
    end
  end

  # -- RESOURCE_TYPES --------------------------------------------------------

  test "RESOURCE_TYPES includes all payer types per 42 CFR 136.61" do
    expected = %w[
      medicare_a medicare_b medicare_d medicaid va_benefits
      private_insurance workers_comp auto_insurance liability_coverage
      state_program tribal_program charity_care
    ]
    assert_equal expected.sort, Corvid::AlternateResourceCheck::RESOURCE_TYPES.sort
  end

  # -- Status enum -----------------------------------------------------------

  test "status enum includes expected values" do
    expected = %w[not_checked checking enrolled not_enrolled pending_enrollment denied exhausted]
    assert_equal expected.sort, Corvid::AlternateResourceCheck.statuses.keys.sort
  end

  # -- More scopes -----------------------------------------------------------

  test "pending scope returns not_checked, checking, and pending_enrollment" do
    with_tenant(TENANT) do
      referral = create_referral
      not_checked = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "not_checked"
      )
      checking = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "checking"
      )
      pe = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "private_insurance", status: "pending_enrollment"
      )
      enrolled = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "va_benefits", status: "enrolled"
      )

      pending_checks = Corvid::AlternateResourceCheck.pending
      assert_includes pending_checks, not_checked
      assert_includes pending_checks, checking
      assert_includes pending_checks, pe
      refute_includes pending_checks, enrolled
    end
  end

  test "federal scope returns Medicare, Medicaid, and VA" do
    with_tenant(TENANT) do
      referral = create_referral
      medicare = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a"
      )
      private_ins = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "private_insurance"
      )

      federal = Corvid::AlternateResourceCheck.federal
      assert_includes federal, medicare
      refute_includes federal, private_ins
    end
  end

  test "private_payer scope returns private insurance types" do
    with_tenant(TENANT) do
      referral = create_referral
      private_ins = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "private_insurance"
      )
      workers_comp = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "workers_comp"
      )
      medicare = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a"
      )

      private_checks = Corvid::AlternateResourceCheck.private_payer
      assert_includes private_checks, private_ins
      assert_includes private_checks, workers_comp
      refute_includes private_checks, medicare
    end
  end

  # -- Class methods ---------------------------------------------------------

  test "all_exhausted? returns false when any resource has active coverage" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "not_enrolled"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "enrolled"
      )
      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  test "all_exhausted? returns false when any check is pending" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "not_enrolled"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "checking"
      )
      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  test "all_exhausted? returns true with mixed exhausted/denied/not_enrolled" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "not_enrolled"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "denied"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "private_insurance", status: "exhausted"
      )
      assert Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  test "any_pending? returns false when no checks pending" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "enrolled"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "not_enrolled"
      )
      refute Corvid::AlternateResourceCheck.any_pending?(referral)
    end
  end

  test "pending_resources returns list of pending resource types" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "checking"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicaid", status: "enrolled"
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "private_insurance", status: "not_checked"
      )

      pending_types = Corvid::AlternateResourceCheck.pending_resources(referral)
      assert_includes pending_types, "medicare_a"
      assert_includes pending_types, "private_insurance"
      refute_includes pending_types, "medicaid"
    end
  end

  # -- Instance methods ------------------------------------------------------

  test "exhausted_or_unavailable? returns true for not_enrolled" do
    check = Corvid::AlternateResourceCheck.new(status: :not_enrolled)
    assert check.exhausted_or_unavailable?
  end

  test "exhausted_or_unavailable? returns true for denied" do
    check = Corvid::AlternateResourceCheck.new(status: :denied)
    assert check.exhausted_or_unavailable?
  end

  test "exhausted_or_unavailable? returns true for exhausted" do
    check = Corvid::AlternateResourceCheck.new(status: :exhausted)
    assert check.exhausted_or_unavailable?
  end

  test "exhausted_or_unavailable? returns false for enrolled" do
    check = Corvid::AlternateResourceCheck.new(status: :enrolled)
    refute check.exhausted_or_unavailable?
  end

  test "has_coverage? returns true for enrolled" do
    check = Corvid::AlternateResourceCheck.new(status: :enrolled)
    assert check.has_coverage?
  end

  test "has_coverage? returns true for pending_enrollment" do
    check = Corvid::AlternateResourceCheck.new(status: :pending_enrollment)
    assert check.has_coverage?
  end

  test "has_coverage? returns false for not_enrolled" do
    check = Corvid::AlternateResourceCheck.new(status: :not_enrolled)
    refute check.has_coverage?
  end

  # -- Resource name ---------------------------------------------------------

  test "resource_name returns human-readable names" do
    test_cases = {
      "medicare_a" => "Medicare Part A",
      "medicare_b" => "Medicare Part B",
      "medicare_d" => "Medicare Part D",
      "medicaid" => "Medicaid",
      "va_benefits" => "VA Benefits",
      "private_insurance" => "Private Insurance",
      "workers_comp" => "Workers' Compensation",
      "auto_insurance" => "Auto Insurance",
      "liability_coverage" => "Liability Coverage",
      "state_program" => "State Program",
      "tribal_program" => "Tribal Program",
      "charity_care" => "Charity Care"
    }
    test_cases.each do |resource_type, expected_name|
      check = Corvid::AlternateResourceCheck.new(resource_type: resource_type)
      assert_equal expected_name, check.resource_name, "Failed for #{resource_type}"
    end
  end

  # -- Coverage summary ------------------------------------------------------

  test "coverage_summary shows status for non-enrolled statuses" do
    check = Corvid::AlternateResourceCheck.new(resource_type: "medicare_a", status: :not_checked)
    assert_equal "Not checked", check.coverage_summary

    check.status = :checking
    assert_equal "Checking...", check.coverage_summary

    check.status = :not_enrolled
    assert_equal "Not enrolled", check.coverage_summary

    check.status = :denied
    assert_equal "Denied", check.coverage_summary

    check.status = :exhausted
    assert_equal "Exhausted", check.coverage_summary

    check.status = :pending_enrollment
    assert_equal "Pending enrollment", check.coverage_summary
  end

  test "coverage_summary uses resource_name when enrolled with no payer_token" do
    check = Corvid::AlternateResourceCheck.new(
      resource_type: "medicare_a", status: :enrolled
    )
    assert_equal "Medicare Part A", check.coverage_summary
  end

  # -- Callbacks -------------------------------------------------------------

  test "sets checked_at when status changes from not_checked" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral, resource_type: "medicare_a", status: "not_checked"
      )
      assert_nil check.checked_at
      check.update!(status: "enrolled")
      assert_not_nil check.checked_at
    end
  end

  test "stores coverage details" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral,
        resource_type: "private_insurance",
        status: "enrolled",
        group_number: "GRP456",
        coverage_start: Date.new(2024, 1, 1),
        coverage_end: Date.new(2024, 12, 31)
      )
      check.reload
      assert_equal "GRP456", check.group_number
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
end
