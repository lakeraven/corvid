# frozen_string_literal: true

require "test_helper"

# Issue #712 D5: placeholder coverage and renewal end dates store as open (nil).
class Corvid::AlternateResourceCheckPlaceholderEndTest < ActiveSupport::TestCase
  TENANT = "tnt_arc_test"
  PATIENT = "pt-712-002"
  INQUIRY_DOS = Date.new(2026, 10, 15)

  test "default placeholder_coverage_end_dates includes 9999-12-31" do
    assert_respond_to Corvid.configuration, :placeholder_coverage_end_dates,
                      "placeholder_coverage_end_dates configuration required (issue #712)"
    assert_includes Corvid.configuration.placeholder_coverage_end_dates, Date.new(9999, 12, 31)
  end

  test "verify! stores nil coverage_end when adapter returns sentinel 9999-12-31" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify_result(
        coverage_end: Date.new(9999, 12, 31),
        renewal_date: nil
      )

      assert verify_with_dos!(check, INQUIRY_DOS)
      check.reload

      assert_nil check.coverage_end,
                 "Sentinel plan end must be stored as open coverage_end nil (issue #712)"
    end
  end

  test "verify! stores nil renewal_date when adapter returns sentinel 9999-12-31" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify_result(
        coverage_end: Date.new(2026, 12, 31),
        renewal_date: Date.new(9999, 12, 31)
      )

      assert verify_with_dos!(check, INQUIRY_DOS)
      check.reload

      assert_nil check.renewal_date,
                 "Sentinel renewal_date must be stored as nil (issue #712)"
    end
  end

  test "verify! stores nil coverage_end when adapter end is beyond placeholder horizon" do
    assert_respond_to Corvid.configuration, :placeholder_coverage_end_horizon_years,
                      "placeholder_coverage_end_horizon_years configuration required (issue #712)"

    horizon = Corvid.configuration.placeholder_coverage_end_horizon_years
    far_end = INQUIRY_DOS + (horizon + 1).years

    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify_result(coverage_end: far_end, renewal_date: nil)

      assert verify_with_dos!(check, INQUIRY_DOS)
      check.reload

      assert_nil check.coverage_end,
                 "Plan end beyond #{horizon} years after inquiry must store as nil (issue #712)"
    end
  end

  test "verify! keeps a real near-term coverage_end" do
    real_end = Date.new(2026, 11, 30)

    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify_result(coverage_end: real_end, renewal_date: nil)

      assert verify_with_dos!(check, INQUIRY_DOS)
      check.reload

      assert_equal real_end, check.coverage_end
    end
  end

  test "verify! keeps a real near-term renewal_date" do
    real_renewal = Date.new(2026, 11, 1)

    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify_result(coverage_end: Date.new(2026, 10, 31), renewal_date: real_renewal)

      assert verify_with_dos!(check, INQUIRY_DOS)
      check.reload

      assert_equal real_renewal, check.renewal_date
    end
  end

  test "renewal tracking does not treat a stored placeholder renewal as current" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify_result(
        coverage_end: Date.new(2026, 12, 31),
        renewal_date: Date.new(9999, 12, 31)
      )

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        assert verify_with_dos!(check, INQUIRY_DOS)
      end
      check.reload

      assert_nil check.renewal_date
      assert check.current_for?(INQUIRY_DOS),
             "Placeholder renewal must not block current_for? when stored as nil (issue #712)"
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
    Corvid::PrcReferral.create!(case: create_case, referral_identifier: "ref_712_ph_#{SecureRandom.hex(3)}")
  end

  def medicaid_check_for(referral)
    Corvid::AlternateResourceCheck.create!(
      prc_referral: referral,
      resource_type: "medicaid"
    )
  end

  def verify_with_dos!(check, date_of_service)
    unless check.method(:verify!).parameters.any? { |type, name| type == :key && name == :date_of_service }
      flunk "verify! must accept date_of_service: keyword (issue #712)"
    end

    check.verify!(date_of_service: date_of_service)
  end

  def stub_verify_result(coverage_end:, renewal_date:)
    Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
      dos = date_of_service || Date.current
      {
        eligible: true,
        coverage_start: Date.new(dos.year, dos.month, 1),
        coverage_end: coverage_end,
        renewal_date: renewal_date,
        date_of_service: dos,
        date_of_service_defaulted: date_of_service.nil?
      }
    end
  end
end
