# frozen_string_literal: true

require "test_helper"

# Issue #712: Medicaid eligibility answers are month-scoped; verify! records inquiry_date_of_service.
class Corvid::AlternateResourceCheckMonthCurrencyTest < ActiveSupport::TestCase
  TENANT = "tnt_arc_test"
  PATIENT = "pt-712-001"

  test "verify! accepts date_of_service keyword" do
    params = Corvid::AlternateResourceCheck.instance_method(:verify!).parameters
    assert params.any? { |type, name| type == :key && name == :date_of_service },
           "verify! must accept date_of_service: (issue #712)"
  end

  test "verify! passes date_of_service to the adapter and stores inquiry_date_of_service" do
    assert_includes Corvid::AlternateResourceCheck.column_names, "inquiry_date_of_service",
                    "inquiry_date_of_service column required (issue #712)"

    inquiry_dos = Date.new(2026, 10, 15)
    received = []
    with_tenant(TENANT) do
      referral = create_referral
      check = medicaid_check_for(referral)

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
        received << date_of_service
        {
          eligible: true,
          coverage_start: Date.new(2026, 1, 1),
          coverage_end: Date.new(2026, 12, 31),
          date_of_service: inquiry_dos,
          date_of_service_defaulted: false
        }
      end

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        assert verify_medicaid!(check, date_of_service: inquiry_dos)
      end
      check.reload

      assert_equal [ inquiry_dos ], received
      assert_equal inquiry_dos, check.inquiry_date_of_service
    end
  end

  test "medicaid verified for 2026-10-31 is not current for 2026-11-01" do
    with_tenant(TENANT) do
      referral = create_referral
      stub_month_scoped_medicaid_adapter
      check = medicaid_check_for(referral)

      travel_to Time.zone.local(2026, 10, 31, 23, 0, 0) do
        assert verify_medicaid!(check, date_of_service: Date.new(2026, 10, 31))
      end
      check.reload

      refute check.current_for?(Date.new(2026, 11, 1)),
             "Medicaid check for October must not carry into November (issue #712)"
    end
  end

  test "medicaid verified for 2026-10-15 is current for 2026-10-20 when fresh and covered" do
    with_tenant(TENANT) do
      referral = create_referral
      stub_month_scoped_medicaid_adapter
      check = medicaid_check_for(referral)

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        assert verify_medicaid!(check, date_of_service: Date.new(2026, 10, 15))
      end
      check.reload

      assert check.current_for?(Date.new(2026, 10, 20))
    end
  end

  test "medicaid with no inquiry date is not current for any date of service" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral,
        resource_type: "medicaid",
        status: "enrolled",
        checked_at: Time.zone.local(2026, 10, 15, 10, 0, 0),
        coverage_start: Date.new(2026, 1, 1),
        coverage_end: Date.new(2026, 12, 31)
      )

      travel_to Time.zone.local(2026, 10, 20, 10, 0, 0) do
        refute check.current_for?(Date.new(2026, 10, 20), as_of: Time.zone.local(2026, 10, 20, 10, 0, 0)),
               "Medicaid without inquiry_date_of_service must not be current (issue #712)"
      end
    end
  end

  test "private insurance month-bounding does not apply across calendar months" do
    with_tenant(TENANT) do
      referral = create_referral
      patient_identifier = referral.case.patient_identifier
      Corvid.adapter.add_coverage(
        patient_identifier,
        coverage_type: "private_insurance",
        payer_name: "MOCK PRIVATE PAYER",
        plan_name: "TEST PLAN 712",
        eligible: true,
        coverage_start: Date.new(2026, 1, 1),
        coverage_end: Date.new(2026, 12, 31)
      )
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "private_insurance"
      )

      travel_to Time.zone.local(2026, 10, 31, 12, 0, 0) do
        assert check.verify!
      end
      check.reload

      travel_to Time.zone.local(2026, 11, 1, 12, 0, 0) do
        assert check.current_for?(Date.new(2026, 11, 1)),
               "Non-medicaid checks keep cross-month current_for? behavior (issue #712)"
      end
    end
  end

  test "host-configured month-bounded resource type is not current in the next month" do
    assert_respond_to Corvid.configuration, :month_bounded_eligibility_resource_types,
                      "month_bounded_eligibility_resource_types configuration required (issue #712)"

    original = Corvid.configuration.month_bounded_eligibility_resource_types
    Corvid.configuration.month_bounded_eligibility_resource_types = %w[medicaid state_program]
    with_tenant(TENANT) do
      referral = create_referral
      patient_identifier = referral.case.patient_identifier
      Corvid.adapter.add_coverage(
        patient_identifier,
        coverage_type: "state_program",
        payer_name: "MOCK STATE PROGRAM PAYER",
        plan_name: "TEST STATE PLAN 712",
        eligible: true,
        coverage_start: Date.new(2026, 1, 1),
        coverage_end: Date.new(2026, 12, 31)
      )
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "state_program"
      )

      travel_to Time.zone.local(2026, 10, 31, 12, 0, 0) do
        assert verify_with_inquiry!(check, date_of_service: Date.new(2026, 10, 31))
      end
      check.reload

      refute check.current_for?(Date.new(2026, 11, 1)),
             "Configured month-bounded types must not carry into the next month (issue #712)"
    end
  ensure
    Corvid.configuration.month_bounded_eligibility_resource_types = original if original
  end

  test "inactive service status with covering plan dates records not_enrolled" do
    with_tenant(TENANT) do
      referral = create_referral
      check = medicaid_check_for(referral)

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
        dos = date_of_service || Date.current
        {
          eligible: true,
          service_active: false,
          coverage_start: Date.new(dos.year, dos.month, 1),
          coverage_end: Date.new(dos.year, dos.month, -1),
          date_of_service: dos,
          date_of_service_defaulted: date_of_service.nil?
        }
      end

      travel_to Time.zone.local(2026, 10, 10, 10, 0, 0) do
        assert verify_medicaid!(check, date_of_service: Date.new(2026, 10, 10))
      end
      check.reload

      assert check.not_enrolled?,
             "service_active: false must record not_enrolled despite covering plan dates (issue #712)"
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: PATIENT,
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_referral
    Corvid::PrcReferral.create!(case: create_case, referral_identifier: "ref_712_#{SecureRandom.hex(3)}")
  end

  def medicaid_check_for(referral)
    Corvid::AlternateResourceCheck.create!(
      prc_referral: referral,
      resource_type: "medicaid"
    )
  end

  def verify_medicaid!(check, date_of_service:)
    verify_with_inquiry!(check, date_of_service: date_of_service)
  end

  def verify_with_inquiry!(check, date_of_service:)
    unless check.method(:verify!).parameters.any? { |type, name| type == :key && name == :date_of_service }
      flunk "verify! must accept date_of_service: keyword (issue #712)"
    end

    check.verify!(date_of_service: date_of_service)
  end

  def stub_month_scoped_medicaid_adapter
    Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
      dos = date_of_service || Date.current
      {
        eligible: true,
        coverage_start: Date.new(dos.year, dos.month, 1),
        coverage_end: Date.new(dos.year, 12, 31),
        date_of_service: dos,
        date_of_service_defaulted: date_of_service.nil?
      }
    end
  end
end
