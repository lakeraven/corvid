# frozen_string_literal: true

require "test_helper"

# Issue #668 (A): date-aware exhaustion and pending detection.
class Corvid::AlternateResourceCheckDateAwareExhaustionTest < ActiveSupport::TestCase
  TENANT = "tnt_test"

  test "all_exhausted? is false when twelve unavailable rows are stale for date of service" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        create_all_twelve_unavailable_checks(referral, checked_at: 31.days.ago)

        refute Corvid::AlternateResourceCheck.all_exhausted?(referral, date_of_service: dos)
        assert_exhaustion_agreement(referral, date_of_service: dos)
      end
    end
  end

  test "all_exhausted? is true when twelve unavailable rows are current for date of service" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        create_all_twelve_unavailable_checks(referral, checked_at: 1.day.ago)

        assert Corvid::AlternateResourceCheck.all_exhausted?(referral, date_of_service: dos)
        assert_exhaustion_agreement(referral, date_of_service: dos)
      end
    end
  end

  test "all_exhausted? is false when seeded checks have nil checked_at" do
    with_tenant(TENANT) do
      referral = create_referral
      previous = create_referral
      create_all_twelve_unavailable_checks(previous, checked_at: 1.day.ago)
      Corvid::AlternateResourceCheck.seed_from_previous!(referral, previous)

      dos = Date.current
      refute Corvid::AlternateResourceCheck.all_exhausted?(referral, date_of_service: dos)
    end
  end

  test "all_exhausted? is false when stored period ends before date of service" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        create_all_twelve_unavailable_checks(referral, checked_at: 1.day.ago)
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update!(
          status: "exhausted",
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 6, 10)
        )

        refute Corvid::AlternateResourceCheck.all_exhausted?(referral, date_of_service: dos)
      end
    end
  end

  test "any_pending? is true when an unavailable row is not current for date of service" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        create_all_twelve_unavailable_checks(referral, checked_at: 31.days.ago)

        assert Corvid::AlternateResourceCheck.any_pending?(referral, date_of_service: dos)
      end
    end
  end

  test "any_pending? is false when all rows are current unavailable determinations" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        create_all_twelve_unavailable_checks(referral, checked_at: 1.day.ago)

        refute Corvid::AlternateResourceCheck.any_pending?(referral, date_of_service: dos)
      end
    end
  end

  test "all_exhausted? without date_of_service defaults to Date.current and requires current checks" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral = create_referral
        create_all_twelve_unavailable_checks(referral, checked_at: 31.days.ago)

        refute Corvid::AlternateResourceCheck.all_exhausted?(referral)
      end
    end
  end

  test "AlternateResourceService passes date_of_service and as_of to exhaustion helpers" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        create_all_twelve_unavailable_checks(referral, checked_at: 1.day.ago)

        assert Corvid::AlternateResourceService.all_exhausted?(referral, date_of_service: dos)
        refute Corvid::AlternateResourceService.has_active_coverage?(referral, date_of_service: dos)
      end
    end
  end

  test "has_active_coverage? ignores stale enrolled rows for date of service" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        Corvid::AlternateResourceCheck.create!(
          prc_referral: referral,
          resource_type: "medicaid",
          status: "enrolled",
          checked_at: 31.days.ago,
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 12, 31),
          renewal_date: Date.new(2025, 12, 1)
        )

        refute Corvid::AlternateResourceService.has_active_coverage?(referral, date_of_service: dos)
      end
    end
  end

  private

  def create_referral
    kase = Corvid::Case.create!(
      patient_identifier: "pt-test-001",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "rf_#{SecureRandom.hex(4)}",
      facility_identifier: "fac_test"
    )
  end

  def create_all_twelve_unavailable_checks(referral, checked_at:, status_overrides: {})
    Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
      status = status_overrides.fetch(type, "not_enrolled")
      Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: type,
        status: status,
        checked_at: %w[not_checked checking].include?(status) ? nil : checked_at
      )
    end
  end

  def assert_exhaustion_agreement(referral, date_of_service:)
    service = Corvid::AlternateResourceService.all_exhausted?(referral, date_of_service: date_of_service)
    model = Corvid::AlternateResourceCheck.all_exhausted?(referral, date_of_service: date_of_service)
    assert_equal service, model
  end
end
