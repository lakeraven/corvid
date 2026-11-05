# frozen_string_literal: true

require "test_helper"

# Issue #668 (B): re-verify stale alternate resource checks before relying on them.
class Corvid::AlternateResourceReverificationTest < ActiveSupport::TestCase
  TENANT = "tnt_test"

  setup do
    @verify_calls = []
    install_verify_eligibility_stub(calls: @verify_calls, eligible: false)
  end

  test "reverify_stale! passes judged date_of_service to the adapter via verify!" do
    with_tenant(TENANT) do
      travel_to Time.zone.local(2026, 10, 27, 12, 0, 0) do
        referral = create_referral
        dos = Date.new(2026, 10, 15)
        exhaust_alternate_resources!(referral, date_of_service: dos, as_of: Time.current)

        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update!(checked_at: 31.days.ago)

        received_dates = []
        install_verify_eligibility_stub do |_pid, type, date_of_service: nil|
          received_dates << date_of_service if type == "medicaid"
          { eligible: false }
        end

        Corvid::AlternateResourceReverification.reverify_stale!(referral, date_of_service: dos)

        assert_equal [ dos ], received_dates,
                     "re-verification must ask the adapter for the date of service being judged (issue #712 / #689 A1)"
      end
    end
  end

  test "reverify_stale! calls verify! only on checks not current for date of service" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        exhaust_alternate_resources!(referral, date_of_service: dos, as_of: Time.current)

        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update!(checked_at: 31.days.ago)

        @verify_calls.clear
        Corvid::AlternateResourceReverification.reverify_stale!(referral, date_of_service: dos)

        assert_equal [ [ referral.case.patient_identifier, "medicaid" ] ], @verify_calls.map { |c| c.first(2) }
      end
    end
  end

  test "reverify_stale! re-verifies seeded checks with nil checked_at" do
    with_tenant(TENANT) do
      referral = create_referral
      previous = create_referral
      exhaust_alternate_resources!(previous)
      Corvid::AlternateResourceCheck.seed_from_previous!(referral, previous)

      @verify_calls.clear
      Corvid::AlternateResourceReverification.reverify_stale!(referral, date_of_service: Date.current)

      assert_equal Corvid::AlternateResourceCheck::RESOURCE_TYPES.size, @verify_calls.size
    end
  end

  test "reverify_stale! re-verifies when stored coverage period ends before date of service" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        exhaust_alternate_resources!(referral, date_of_service: dos)
        medicare = referral.alternate_resource_checks.find_by!(resource_type: "medicare_a")
        medicare.update!(
          status: "exhausted",
          coverage_start: Date.new(2025, 1, 1),
          coverage_end: Date.new(2025, 6, 10)
        )

        @verify_calls.clear
        Corvid::AlternateResourceReverification.reverify_stale!(referral, date_of_service: dos)

        assert_includes @verify_calls.map { |c| c[1] }, "medicare_a"
      end
    end
  end

  test "reverify_stale! leaves current checks alone when adapter would raise" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        exhaust_alternate_resources!(referral, date_of_service: dos)

        Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
          raise StandardError, "adapter down"
        end

        before = referral.alternate_resource_checks.pluck(:resource_type, :checked_at)
        Corvid::AlternateResourceReverification.reverify_stale!(referral, date_of_service: dos)
        after = referral.alternate_resource_checks.reload.pluck(:resource_type, :checked_at)

        assert_equal before, after
      end
    end
  end

  test "reverify_stale! fails closed when adapter returns unreadable answer" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        exhaust_alternate_resources!(referral, date_of_service: dos)
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update!(checked_at: 31.days.ago, status: "not_enrolled")

        install_verify_eligibility_stub do |_pid, type, date_of_service: nil|
          type == "medicaid" ? { error: "timeout" } : { eligible: false }
        end

        result = Corvid::AlternateResourceReverification.reverify_stale!(referral, date_of_service: dos)

        refute result
        refute Corvid::AlternateResourceCheck.all_exhausted?(referral, date_of_service: dos)
        assert Corvid::AlternateResourceCheck.any_pending?(referral, date_of_service: dos)
      end
    end
  end

  test "stale not_enrolled that cannot be re-confirmed counts as pending not exhausted" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral = create_referral
        dos = Date.new(2025, 6, 15)
        exhaust_alternate_resources!(referral, date_of_service: dos)
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update!(checked_at: 31.days.ago)

        Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
          nil
        end

        Corvid::AlternateResourceReverification.reverify_stale!(referral, date_of_service: dos)

        assert Corvid::AlternateResourceCheck.any_pending?(referral, date_of_service: dos)
        refute Corvid::AlternateResourceCheck.all_exhausted?(referral, date_of_service: dos)
      end
    end
  end

  private

  def create_referral
    kase = Corvid::Case.create!(
      patient_identifier: "pt-test-002",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "rf_#{SecureRandom.hex(4)}",
      facility_identifier: "fac_test"
    )
  end
end
