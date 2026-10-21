# frozen_string_literal: true

require "test_helper"

class Corvid::AlternateResourceCheckTest < ActiveSupport::TestCase
  TENANT = "tnt_arc_test"

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

  test "configurable max-age types match RESOURCE_TYPES" do
    assert_equal Corvid::AlternateResourceCheck::RESOURCE_TYPES.sort,
      Corvid::Configuration::ALTERNATE_RESOURCE_TYPES.sort
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
      create_all_twelve_unavailable_checks(referral)

      assert Corvid::AlternateResourceCheck.all_exhausted?(referral)
    end
  end

  test "all_exhausted? false when referral has no alternate resource checks" do
    with_tenant(TENANT) do
      referral = create_referral

      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
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

      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "all_exhausted? false when all twelve rows exist but one is not_checked" do
    with_tenant(TENANT) do
      referral = create_referral
      create_all_twelve_unavailable_checks(referral, "tribal_program" => "not_checked")

      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "all_exhausted? false when all twelve rows exist but one is checking" do
    with_tenant(TENANT) do
      referral = create_referral
      create_all_twelve_unavailable_checks(referral, "workers_comp" => "checking")

      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "all_exhausted? false when all twelve rows exist but one is pending_enrollment" do
    with_tenant(TENANT) do
      referral = create_referral
      create_all_twelve_unavailable_checks(referral, "state_program" => "pending_enrollment")

      refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
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
    expected = %w[not_checked checking enrolled not_enrolled pending_enrollment denied exhausted coordinated]
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
      create_all_twelve_unavailable_checks(
        referral,
        "medicare_a" => "not_enrolled",
        "medicaid" => "denied",
        "private_insurance" => "exhausted"
      )

      assert Corvid::AlternateResourceCheck.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
    end
  end

  test "coordinated status persists and counts toward all_exhausted among twelve checks" do
    with_tenant(TENANT) do
      referral = create_referral
      create_all_twelve_unavailable_checks(referral, "medicaid" => "coordinated")

      coordinated = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
      assert_equal "coordinated", coordinated.status
      coordinated.reload
      assert_equal "coordinated", coordinated.status

      assert Corvid::AlternateResourceCheck.all_exhausted?(referral)
      assert_exhaustion_agreement(referral)
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

  # Coordinated coverage is still active; only its coordination is done.
  test "has_coverage? returns true for coordinated" do
    check = Corvid::AlternateResourceCheck.new(status: :coordinated)
    assert check.has_coverage?
    assert check.exhausted_or_unavailable?
  end

  test "active_coverage scope includes coordinated" do
    with_tenant(TENANT) do
      referral = create_referral
      coordinated = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral, resource_type: "medicare_a", status: "coordinated"
      )

      assert_includes Corvid::AlternateResourceCheck.active_coverage, coordinated
    end
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

  test "sets checked_at when status changes from checking" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral, resource_type: "medicare_a", status: "checking"
      )
      check.update!(status: "not_enrolled")
      assert_not_nil check.checked_at
    end
  end

  test "checked_at only set when transitioning from not_checked or checking" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral, resource_type: "medicare_a", status: "enrolled"
      )
      # Starting from enrolled means checked_at should not be set by the callback
      assert_nil check.checked_at
    end
  end

  test "stale? returns true when never checked" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.new(checked_at: nil)
      assert check.stale?
    end
  end

  test "seed_from_previous! copies coordinated as enrolled on the new referral" do
    with_tenant("tnt_test") do
      previous = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: previous,
        resource_type: "medicaid",
        status: "coordinated",
        checked_at: 2.days.ago,
        policy_token: "POL-MED",
        coverage_start: Date.new(2024, 1, 1),
        coverage_end: Date.new(2024, 12, 31),
        renewal_date: Date.new(2024, 6, 1)
      )
      Corvid::AlternateResourceCheck.create!(
        prc_referral: previous,
        resource_type: "medicare_a",
        status: "not_enrolled",
        checked_at: 1.day.ago,
        policy_token: "POL-MCR"
      )

      new_referral = create_referral
      Corvid::AlternateResourceCheck.seed_from_previous!(new_referral, previous)

      medicaid = new_referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
      assert_equal "enrolled", medicaid.status
      assert_equal "POL-MED", medicaid.policy_token
      assert_nil medicaid.checked_at
      assert_nil medicaid.coverage_start
      assert_nil medicaid.coverage_end
      assert_nil medicaid.renewal_date

      medicare = new_referral.alternate_resource_checks.find_by!(resource_type: "medicare_a")
      assert_equal "not_enrolled", medicare.status
      assert_equal "POL-MCR", medicare.policy_token
      assert_nil medicare.checked_at
    end
  end

  test "seed_from_previous! leaves seeded checks not current_for? any date of service" do
    with_tenant("tnt_test") do
      previous = create_referral
      Corvid::AlternateResourceCheck.create!(
        prc_referral: previous,
        resource_type: "medicaid",
        status: "enrolled",
        checked_at: 1.day.ago,
        coverage_start: Date.new(2020, 1, 1),
        coverage_end: Date.new(2030, 12, 31)
      )

      new_referral = create_referral
      Corvid::AlternateResourceCheck.seed_from_previous!(new_referral, previous)

      seeded = new_referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
      dos = Date.new(2025, 6, 15)
      refute seeded.current_for?(dos)
    end
  end

  # -- Issue #640: coverage period on verify! ---------------------------------

  test "verify! stores coverage period and renewal date from adapter as Date values" do
    with_tenant("tnt_test") do
      referral = create_referral
      patient_identifier = referral.case.patient_identifier
      coverage_start = Date.new(2025, 3, 1)
      coverage_end = Date.new(2025, 9, 30)
      renewal_date = Date.new(2025, 8, 15)

      Corvid.adapter.add_coverage(
        patient_identifier,
        resource_type: "medicaid",
        eligible: true,
        coverage_start: coverage_start,
        coverage_end: coverage_end,
        renewal_date: renewal_date
      )

      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicaid"
      )
      assert check.verify!
      check.reload

      assert_equal coverage_start, check.coverage_start
      assert_equal coverage_end, check.coverage_end
      assert_equal renewal_date, check.renewal_date
    end
  end

  test "verify! stores nil coverage fields when adapter omits coverage date keys" do
    with_tenant("tnt_test") do
      referral = create_referral
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicare_a"
      )

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type|
        { eligible: true, policy_token: "TOK-OMIT" }
      end

      assert check.verify!
      check.reload

      assert_equal "TOK-OMIT", check.policy_token
      assert_nil check.coverage_start
      assert_nil check.coverage_end
      assert_nil check.renewal_date
    end
  end

  test "verify! returns false and leaves row unchanged when adapter sends non-Date coverage values" do
    with_tenant("tnt_test") do
      referral = create_referral
      frozen_checked_at = Time.zone.parse("2025-01-15 10:00:00 UTC")
      stored_start = Date.new(2020, 1, 1)
      stored_end = Date.new(2020, 12, 31)
      stored_renewal = Date.new(2020, 6, 1)

      non_date_samples = [
        [ "medicare_b", { coverage_start: "2025-01-01", coverage_end: nil, renewal_date: nil } ],
        [ "medicare_d", { coverage_start: nil, coverage_end: Time.utc(2025, 12, 31), renewal_date: nil } ],
        [
          "va_benefits",
          {
            coverage_start: nil,
            coverage_end: nil,
            renewal_date: Time.zone.parse("2025-08-15 00:00:00 UTC")
          }
        ],
        [
          "private_insurance",
          { coverage_start: nil, coverage_end: nil, renewal_date: DateTime.new(2025, 8, 15) }
        ]
      ]

      non_date_samples.each do |resource_type, adapter_dates|
        check = Corvid::AlternateResourceCheck.create!(
          prc_referral: referral,
          resource_type: resource_type,
          status: "enrolled",
          checked_at: frozen_checked_at,
          policy_token: "TOK-KEEP",
          coverage_start: stored_start,
          coverage_end: stored_end,
          renewal_date: stored_renewal
        )

        Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type|
          { eligible: true, policy_token: "TOK-NEW", **adapter_dates }
        end

        refute check.verify!
        check.reload

        assert_equal "enrolled", check.status
        assert_equal frozen_checked_at, check.checked_at
        assert_equal "TOK-KEEP", check.policy_token
        assert_equal stored_start, check.coverage_start
        assert_equal stored_end, check.coverage_end
        assert_equal stored_renewal, check.renewal_date
      end
    end
  end

  # -- Issue #640: current_for? -----------------------------------------------

  test "current_for? raises ArgumentError when date_of_service is not a Date" do
    check = Corvid::AlternateResourceCheck.new(
      resource_type: "medicaid",
      status: "not_enrolled",
      checked_at: Time.current
    )
    assert_raises(ArgumentError) { check.current_for?("2025-06-01") }
  end

  test "current_for? raises ArgumentError when as_of is a Date" do
    check = Corvid::AlternateResourceCheck.new(
      resource_type: "medicaid",
      status: "enrolled",
      checked_at: Time.current,
      coverage_start: Date.new(2025, 1, 1),
      coverage_end: Date.new(2025, 12, 31)
    )
    dos = Date.new(2025, 6, 1)
    assert_raises(ArgumentError) { check.current_for?(dos, as_of: Date.new(2025, 6, 15)) }
  end

  test "current_for? raises ArgumentError when as_of is a String" do
    check = Corvid::AlternateResourceCheck.new(
      resource_type: "medicaid",
      status: "enrolled",
      checked_at: Time.current,
      coverage_start: Date.new(2025, 1, 1),
      coverage_end: Date.new(2025, 12, 31)
    )
    dos = Date.new(2025, 6, 1)
    assert_raises(ArgumentError) { check.current_for?(dos, as_of: "2025-06-15") }
  end

  test "current_for? is false when checked_at is after as_of" do
    check = Corvid::AlternateResourceCheck.new(
      resource_type: "medicaid",
      status: "enrolled",
      checked_at: Time.zone.parse("2026-03-01 12:00:00 UTC"),
      coverage_start: Date.new(2025, 1, 1),
      coverage_end: Date.new(2026, 12, 31)
    )
    dos = Date.new(2025, 6, 1)
    as_of = Time.zone.parse("2025-03-01 12:00:00 UTC")

    refute check.current_for?(dos, as_of: as_of)
  end

  test "current_for? is false for not_checked and checking regardless of age" do
    with_tenant("tnt_test") do
      dos = Date.new(2025, 6, 1)
      not_checked = Corvid::AlternateResourceCheck.new(
        resource_type: "medicaid", status: "not_checked", checked_at: Time.current
      )
      checking = Corvid::AlternateResourceCheck.new(
        resource_type: "medicaid", status: "checking", checked_at: Time.current
      )

      refute not_checked.current_for?(dos)
      refute checking.current_for?(dos)
    end
  end

  test "current_for? is true for fresh not_enrolled without coverage period" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        dos = Date.new(2025, 6, 1)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "private_insurance",
          status: "not_enrolled",
          checked_at: 10.days.ago
        )
        assert check.current_for?(dos)
      end
    end
  end

  test "current_for? is false for not_enrolled when date of service is inside stored coverage period" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        dos = Date.new(2025, 6, 1)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "not_enrolled",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 12, 31),
          renewal_date: Date.new(2025, 12, 1)
        )

        refute check.current_for?(dos)
      end
    end
  end

  test "current_for? is true for fresh exhausted when date of service is inside stored coverage period" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        dos = Date.new(2025, 6, 1)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "exhausted",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 12, 31),
          renewal_date: Date.new(2025, 12, 1)
        )

        assert check.current_for?(dos)
      end
    end
  end

  test "current_for? is true for fresh denied when date of service is inside stored coverage period" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        dos = Date.new(2025, 6, 1)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "denied",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 12, 31),
          renewal_date: Date.new(2025, 12, 1)
        )

        assert check.current_for?(dos)
      end
    end
  end

  # exhausted and denied are current only inside a stored period (#640).
  %w[exhausted denied].each do |negative_status|
    test "current_for? is false for fresh #{negative_status} when date of service is after stored period" do
      with_tenant("tnt_test") do
        travel_to Time.zone.parse("2027-01-10 12:00:00 UTC") do
          check = Corvid::AlternateResourceCheck.new(
            resource_type: "medicaid",
            status: negative_status,
            checked_at: 1.day.ago,
            coverage_start: Date.new(2026, 1, 1),
            coverage_end: Date.new(2026, 12, 31)
          )

          refute check.current_for?(Date.new(2027, 1, 5))
        end
      end
    end

    test "current_for? is false for fresh #{negative_status} when date of service is before stored period" do
      with_tenant("tnt_test") do
        travel_to Time.zone.parse("2026-01-10 12:00:00 UTC") do
          check = Corvid::AlternateResourceCheck.new(
            resource_type: "medicaid",
            status: negative_status,
            checked_at: 1.day.ago,
            coverage_start: Date.new(2026, 1, 1),
            coverage_end: Date.new(2026, 12, 31)
          )

          refute check.current_for?(Date.new(2025, 12, 31))
        end
      end
    end

    test "current_for? respects a one-sided stored period for fresh #{negative_status}" do
      with_tenant("tnt_test") do
        travel_to Time.zone.parse("2027-01-10 12:00:00 UTC") do
          ended = Corvid::AlternateResourceCheck.new(
            resource_type: "medicaid", status: negative_status, checked_at: 1.day.ago,
            coverage_start: nil, coverage_end: Date.new(2026, 12, 31)
          )
          started = Corvid::AlternateResourceCheck.new(
            resource_type: "medicaid", status: negative_status, checked_at: 1.day.ago,
            coverage_start: Date.new(2027, 2, 1), coverage_end: nil
          )

          assert ended.current_for?(Date.new(2026, 12, 31))
          refute ended.current_for?(Date.new(2027, 1, 1))
          refute started.current_for?(Date.new(2027, 1, 5))
          assert started.current_for?(Date.new(2027, 2, 1))
        end
      end
    end

    test "current_for? is true for fresh #{negative_status} with no stored period" do
      with_tenant("tnt_test") do
        travel_to Time.zone.parse("2027-01-10 12:00:00 UTC") do
          check = Corvid::AlternateResourceCheck.new(
            resource_type: "medicaid", status: negative_status, checked_at: 1.day.ago
          )

          assert check.current_for?(Date.new(2027, 1, 5))
        end
      end
    end
  end

  test "current_for? is false for not_enrolled when only coverage_end covers date of service on or before end" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "private_insurance",
          status: "not_enrolled",
          checked_at: 1.day.ago,
          coverage_start: nil,
          coverage_end: Date.new(2025, 12, 31)
        )

        refute check.current_for?(Date.new(2025, 6, 1))
        refute check.current_for?(Date.new(2025, 12, 31))
      end
    end
  end

  test "current_for? is false for not_enrolled when only coverage_start covers date of service on or after start" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "private_insurance",
          status: "not_enrolled",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: nil
        )

        refute check.current_for?(Date.new(2025, 6, 1))
        refute check.current_for?(Date.new(2025, 1, 1))
      end
    end
  end

  test "current_for? applies freshness for negative status when date of service is outside stored coverage period" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        dos = Date.new(2025, 6, 1)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "private_insurance",
          status: "not_enrolled",
          checked_at: 10.days.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 5, 31)
        )

        assert check.current_for?(dos)
      end
    end
  end

  test "current_for? is false for enrolled coverage without coverage_start" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        dos = Date.new(2025, 6, 1)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "enrolled",
          checked_at: 1.day.ago,
          coverage_start: nil,
          coverage_end: Date.new(2025, 12, 31)
        )
        refute check.current_for?(dos)
      end
    end
  end

  test "current_for? medicaid 31 days old is not current while medicare 31 days old is current" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        dos = Date.new(2025, 6, 15)
        as_of = Time.current
        coverage = {
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 12, 31),
          renewal_date: Date.new(2025, 12, 1)
        }

        medicaid = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "enrolled",
          checked_at: 31.days.ago,
          **coverage
        )
        medicare = Corvid::AlternateResourceCheck.new(
          resource_type: "medicare_a",
          status: "enrolled",
          checked_at: 31.days.ago,
          **coverage
        )

        refute medicaid.current_for?(dos, as_of: as_of)
        assert medicare.current_for?(dos, as_of: as_of)
      end
    end
  end

  test "current_for? is true when checked_at is exactly at configured max age" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        dos = Date.new(2025, 6, 15)
        as_of = Time.current
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "enrolled",
          checked_at: 30.days.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: nil
        )

        assert check.current_for?(dos, as_of: as_of)
      end
    end
  end

  test "current_for? is false when date of service is before coverage_start" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "enrolled",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 6, 10),
          coverage_end: Date.new(2025, 12, 31)
        )

        refute check.current_for?(Date.new(2025, 6, 9))
      end
    end
  end

  test "current_for? is false when date of service is after coverage_end" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "enrolled",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 6, 10)
        )

        refute check.current_for?(Date.new(2025, 6, 11))
      end
    end
  end

  test "current_for? is false when renewal_date is before date of service" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicare_b",
          status: "pending_enrollment",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 12, 31),
          renewal_date: Date.new(2025, 6, 10)
        )

        refute check.current_for?(Date.new(2025, 6, 11))
      end
    end
  end

  test "current_for? is false when renewal_date is before as_of date" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        dos = Date.new(2025, 6, 20)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicare_d",
          status: "coordinated",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 12, 31),
          renewal_date: Date.new(2025, 6, 14)
        )

        refute check.current_for?(dos, as_of: Time.current)
      end
    end
  end

  test "current_for? renewal check uses application time zone for as_of calendar date" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2026-10-22 12:00:00 UTC") do
        dos = Date.new(2026, 10, 15)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicare_a",
          status: "enrolled",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2026, 1, 1),
          coverage_end: Date.new(2026, 12, 31),
          renewal_date: Date.new(2026, 10, 21)
        )

        as_of_utc = Time.utc(2026, 10, 22, 3)
        as_of_offset = as_of_utc.getlocal("-12:00")

        refute check.current_for?(dos, as_of: as_of_utc)
        refute check.current_for?(dos, as_of: as_of_offset)
      end
    end
  end

  test "current_for? is true when renewal_date is on or after date of service and as_of date" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        dos = Date.new(2025, 6, 10)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "va_benefits",
          status: "enrolled",
          checked_at: 1.day.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 12, 31),
          renewal_date: Date.new(2025, 6, 15)
        )

        assert check.current_for?(dos, as_of: Time.current)
      end
    end
  end

  test "current_for? respects overridden alternate_resource_check_max_age" do
    with_tenant("tnt_test") do
      Corvid.configure do |c|
        c.alternate_resource_check_max_age = { "medicaid" => 60.days }
      end

      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        dos = Date.new(2025, 6, 15)
        check = Corvid::AlternateResourceCheck.new(
          resource_type: "medicaid",
          status: "enrolled",
          checked_at: 31.days.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: nil
        )

        assert check.current_for?(dos, as_of: Time.current)
      end
    ensure
      Corvid.reset_configuration!
    end
  end

  test "mark_coordinated! sets coordinated from enrolled without changing checked_at" do
    with_tenant("tnt_test") do
      verification_time = Time.zone.parse("2026-01-01 12:00:00 UTC")
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral,
        resource_type: "medicaid",
        status: "enrolled",
        checked_at: verification_time
      )
      travel_to Time.zone.parse("2026-01-01 13:00:00 UTC") do
        assert check.mark_coordinated!
        check.reload
        assert check.coordinated?
        assert_equal verification_time, check.checked_at
      end
    end
  end

  test "mark_coordinated! does not refresh freshness for coordinated medicaid check" do
    with_tenant("tnt_test") do
      verification_time = Time.zone.parse("2026-01-01 12:00:00 UTC")
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral,
        resource_type: "medicaid",
        status: "enrolled",
        checked_at: verification_time,
        coverage_start: Date.new(2026, 1, 1),
        coverage_end: Date.new(2026, 12, 31)
      )

      travel_to Time.zone.parse("2026-01-30 12:00:00 UTC") do
        assert check.mark_coordinated!
        check.reload
        assert_equal verification_time, check.checked_at
      end

      travel_to Time.zone.parse("2026-02-25 12:00:00 UTC") do
        dos = Date.new(2026, 2, 25)
        refute check.current_for?(dos, as_of: Time.current)
      end
    end
  end

  test "mark_coordinated! raises from non-enrolled status" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral,
        resource_type: "medicare_a",
        status: "not_enrolled"
      )

      assert_raises(ArgumentError, match: /not active/) do
        check.mark_coordinated!
      end
    end
  end

  test "verify! keeps coordinated when adapter reports eligible coverage with same policy_token" do
    with_tenant(TENANT) do
      referral = create_referral
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicaid",
        status: "coordinated",
        policy_token: "TOK-A",
        checked_at: 1.day.ago
      )

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type|
        { eligible: true, policy_token: "TOK-A" }
      end

      assert check.verify!
      check.reload
      assert check.coordinated?
      assert_equal "TOK-A", check.policy_token
    end
  end

  test "verify! on coordinated moves to enrolled when adapter returns different policy_token" do
    with_tenant(TENANT) do
      referral = create_referral
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicaid",
        status: "coordinated",
        policy_token: "TOK-A"
      )

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type|
        { eligible: true, policy_token: "TOK-B" }
      end

      assert check.verify!
      check.reload
      assert check.enrolled?
      assert_equal "TOK-B", check.policy_token
    end
  end

  test "verify! on coordinated moves to enrolled when adapter omits policy_token" do
    with_tenant(TENANT) do
      referral = create_referral
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicaid",
        status: "coordinated",
        policy_token: "TOK-A"
      )

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type|
        { eligible: true }
      end

      assert check.verify!
      check.reload
      assert check.enrolled?
    end
  end

  test "verify! on coordinated moves to not_enrolled when adapter reports ineligible" do
    with_tenant(TENANT) do
      referral = create_referral
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicaid",
        status: "coordinated"
      )

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type|
        { eligible: false }
      end

      assert check.verify!
      check.reload
      assert check.not_enrolled?
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

  def create_all_twelve_unavailable_checks(referral, status_overrides = {})
    Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: type,
        status: status_overrides.fetch(type, "not_enrolled")
      )
    end
  end

  def assert_exhaustion_agreement(referral)
    service = Corvid::AlternateResourceService.all_exhausted?(referral)
    model = Corvid::AlternateResourceCheck.all_exhausted?(referral)
    assert_equal service, model, "AlternateResourceService and AlternateResourceCheck must agree"
  end
end
