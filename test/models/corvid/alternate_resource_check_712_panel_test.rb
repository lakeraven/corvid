# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Issue #712 review panel: binding behavior pins (tests only).
class Corvid::AlternateResourceCheck712PanelTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TENANT = "tnt_arc_test"
  PATIENT = "pt-712-panel-001"

  setup do
    @config_snapshot = snapshot_configuration
    @max_age_snapshot = Corvid.configuration.alternate_resource_check_max_age
  end

  teardown do
    restore_configuration(@config_snapshot)
    Corvid.configuration.alternate_resource_check_max_age = @max_age_snapshot
  end

  # R2: present non-boolean service_active makes the answer unreadable.
  test "verify! rejects service_active string false and changes nothing" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      before = check.attributes.slice("status", "checked_at", "inquiry_date_of_service")

      stub_verify(eligible: true, service_active: "false")

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        refute verify_with_dos!(check, Date.new(2026, 10, 15))
      end
      check.reload

      assert_equal before, check.attributes.slice("status", "checked_at", "inquiry_date_of_service")
    end
  end

  test "verify! rejects service_active zero and changes nothing" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      before_status = check.status

      stub_verify(eligible: true, service_active: 0)

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        refute verify_with_dos!(check, Date.new(2026, 10, 15))
      end
      check.reload

      assert_equal before_status, check.status
    end
  end

  # R4: adapter echo month must match the date asked.
  test "verify! rejects adapter date_of_service that differs from the keyword" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      asked = Date.new(2026, 10, 15)

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
        {
          eligible: true,
          coverage_start: Date.new(2026, 10, 1),
          coverage_end: Date.new(2026, 10, 31),
          date_of_service: Date.new(2026, 11, 1),
          date_of_service_defaulted: false
        }
      end

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        refute check.verify!(date_of_service: asked)
      end
      check.reload

      assert check.not_checked?
      assert_nil check.inquiry_date_of_service
    end
  end

  # Round 2: when a date was asked, the adapter must echo it exactly.
  test "verify! rejects adapter omitting date_of_service when a date was asked" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      inquiry = Date.new(2026, 10, 15)
      before = check.attributes.slice("status", "checked_at", "inquiry_date_of_service")
      stub_verify_omitting_date(eligible: true, coverage_end: Date.new(2026, 12, 31))

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        refute check.verify!(date_of_service: inquiry)
      end
      check.reload

      assert_equal before, check.attributes.slice("status", "checked_at", "inquiry_date_of_service")
      assert check.not_checked?
    end
  end

  test "verify! rejects adapter nil date_of_service when a date was asked" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      asked = Date.new(2026, 10, 15)

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
        {
          eligible: true,
          coverage_start: Date.new(2026, 10, 1),
          coverage_end: Date.new(2026, 10, 31),
          date_of_service: nil,
          date_of_service_defaulted: false
        }
      end

      refute check.verify!(date_of_service: asked)
      check.reload
      assert check.not_checked?
    end
  end

  test "verify! rejects adapter date_of_service mismatch when asked date is referral service_date" do
    with_tenant(TENANT) do
      referral = create_referral
      service_date = Date.new(2026, 10, 15)
      referral.define_singleton_method(:has_attribute?) do |name|
        name == :service_date || super(name)
      end
      referral.define_singleton_method(:service_date) { service_date }
      check = medicaid_check_for(referral)

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
        {
          eligible: true,
          coverage_start: Date.new(2026, 10, 1),
          coverage_end: Date.new(2026, 10, 31),
          date_of_service: Date.new(2026, 11, 1),
          date_of_service_defaulted: false
        }
      end

      refute check.verify!
      check.reload
      assert check.not_checked?
      assert_nil check.inquiry_date_of_service
    end
  end

  test "verify! raises ArgumentError when date_of_service is a String" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)

      assert_raises(ArgumentError) { check.verify!(date_of_service: "2026-10-15") }
    end
  end

  test "verify! raises ArgumentError when date_of_service is a Time" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)

      assert_raises(ArgumentError) do
        check.verify!(date_of_service: Time.zone.local(2026, 10, 15, 12, 0, 0))
      end
    end
  end

  test "verify! raises ArgumentError when date_of_service is a DateTime" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)

      assert_raises(ArgumentError) do
        check.verify!(date_of_service: DateTime.new(2026, 10, 15, 12, 0, 0))
      end
    end
  end

  test "verify! nils coverage_end beyond horizon when adapter omits date and no inquiry was asked" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      far_end = Date.current + 40.years
      stub_verify_omitting_date(eligible: true, coverage_end: far_end)

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        assert check.verify!
      end
      check.reload

      assert_nil check.coverage_end,
                 "Horizon without inquiry date measures from answer time (issue #712 R5)"
    end
  end

  # R6: re-verify without a date clears a previous inquiry date.
  test "re-verify without date_of_service clears inquiry_date_of_service when adapter omits date" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      first_inquiry = Date.new(2026, 10, 15)

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
        dos = date_of_service || Date.current
        base = {
          eligible: true,
          coverage_start: Date.new(dos.year, dos.month, 1),
          coverage_end: Date.new(dos.year, dos.month, -1)
        }
        if date_of_service
          base.merge(date_of_service: dos, date_of_service_defaulted: false)
        else
          base
        end
      end

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        assert check.verify!(date_of_service: first_inquiry)
      end
      check.reload
      assert_equal first_inquiry, check.inquiry_date_of_service

      travel_to Time.zone.local(2026, 10, 16, 10, 0, 0) do
        assert check.verify!
      end
      check.reload

      assert_nil check.inquiry_date_of_service,
                 "Must not retain prior inquiry when re-verify asked for no date (issue #712 R6)"
    end
  end

  # R7: MedicaidEligibilityGroupService receives inquiry_date_of_service first.
  test "verify! passes inquiry_date_of_service to MedicaidEligibilityGroupService#record!" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      inquiry = Date.new(2026, 10, 20)
      Corvid.adapter.add_coverage(
        PATIENT,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        plan_name: "TEST PLAN 712"
      )

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
        dos = date_of_service || Date.current
        {
          eligible: true,
          coverage_start: Date.new(dos.year, dos.month, 1),
          coverage_end: Date.new(dos.year, dos.month, -1),
          date_of_service: dos,
          date_of_service_defaulted: false,
          policy_token: "po_test_712"
        }
      end

      recorder = RecordingMedicaidEligibilityGroupService.new
      Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
        travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
          assert check.verify!(date_of_service: inquiry)
        end
      end

      assert_equal 1, recorder.calls.size
      assert_equal inquiry, recorder.calls.first[:date_of_service],
                   "record! must use inquiry_date_of_service, not checked_at.to_date (issue #712 R7)"
    end
  end

  # R12: month compare includes year; freshness can still hold across that boundary.
  test "medicaid verified 2026-10-15 is not current for 2027-10-15 but is for 2026-10-20 when still fresh" do
    Corvid.configuration.alternate_resource_check_max_age = { "medicaid" => 400.days }

    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      inquiry = Date.new(2026, 10, 15)

      stub_verify(
        eligible: true,
        coverage_start: Date.new(2026, 1, 1),
        coverage_end: Date.new(2027, 12, 31),
        echoed_inquiry: inquiry
      )

      travel_to Time.zone.local(2026, 10, 15, 10, 0, 0) do
        assert verify_with_dos!(check, inquiry)
      end
      check.reload

      as_of = Time.zone.local(2027, 10, 16, 12, 0, 0)
      travel_to as_of do
        refute check.current_for?(Date.new(2027, 10, 15), as_of: as_of),
               "Same month/day in a later year must not be current for month-bounded Medicaid (issue #712)"
        assert check.current_for?(Date.new(2026, 10, 20), as_of: as_of),
               "Same inquiry year-month must stay current for another day in that month (issue #712)"
      end
    end
  end

  # R12: horizon is strictly more than N years.
  test "verify! keeps coverage_end exactly placeholder horizon years after inquiry" do
    inquiry = Date.new(2026, 10, 15)
    exact_end = inquiry + 25.years

    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify(eligible: true, coverage_end: exact_end, echoed_inquiry: inquiry)

      assert verify_with_dos!(check, inquiry)
      check.reload

      assert_equal exact_end, check.coverage_end
    end
  end

  test "verify! keeps coverage_end ten years after inquiry when horizon years is zero" do
    Corvid.configuration.placeholder_coverage_end_horizon_years = 0
    inquiry = Date.new(2026, 10, 15)
    end_ten_years_out = inquiry + 10.years

    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify(eligible: true, coverage_end: end_ten_years_out, echoed_inquiry: inquiry)

      assert verify_with_dos!(check, inquiry)
      check.reload

      assert_equal end_ten_years_out, check.coverage_end,
                 "Horizon years 0 must fall back to 25 and keep ends within that span (issue #712)"
    end
  end

  test "verify! keeps coverage_end ten years after inquiry when horizon years is negative" do
    Corvid.configuration.placeholder_coverage_end_horizon_years = -1
    inquiry = Date.new(2026, 10, 15)
    end_ten_years_out = inquiry + 10.years

    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify(eligible: true, coverage_end: end_ten_years_out, echoed_inquiry: inquiry)

      assert verify_with_dos!(check, inquiry)
      check.reload

      assert_equal end_ten_years_out, check.coverage_end,
                 "Horizon years -1 must fall back to 25 and keep ends within that span (issue #712)"
    end
  end

  test "verify! nils coverage_end one day beyond placeholder horizon" do
    inquiry = Date.new(2026, 10, 15)
    beyond_end = inquiry + 25.years + 1

    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      stub_verify(eligible: true, coverage_end: beyond_end, echoed_inquiry: inquiry)

      assert verify_with_dos!(check, inquiry)
      check.reload

      assert_nil check.coverage_end
    end
  end

  # R12: DateTime in adapter result is unreadable.
  test "verify! rejects DateTime date_of_service in adapter result" do
    with_tenant(TENANT) do
      check = medicaid_check_for(create_referral)
      asked = Date.new(2026, 10, 15)

      Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
        {
          eligible: true,
          coverage_start: Date.new(2026, 10, 1),
          coverage_end: Date.new(2026, 10, 31),
          date_of_service: DateTime.new(2026, 10, 15, 12, 0, 0),
          date_of_service_defaulted: false
        }
      end

      refute check.verify!(date_of_service: asked)
      check.reload
      assert check.not_checked?
    end
  end

  test "verify! records not_enrolled when mock coverage row has service_active false" do
    with_tenant(TENANT) do
      referral = create_referral
      patient_identifier = referral.case.patient_identifier
      Corvid.adapter.add_coverage(
        patient_identifier,
        coverage_type: "medicaid",
        eligible: true,
        service_active: false,
        coverage_start: Date.new(2026, 1, 1),
        coverage_end: Date.new(2026, 12, 31)
      )
      check = medicaid_check_for(referral)

      travel_to Time.zone.local(2026, 10, 10, 10, 0, 0) do
        assert check.verify!(date_of_service: Date.new(2026, 10, 10))
      end
      check.reload

      assert check.not_enrolled?,
             "service_active false from recorded coverage must yield not_enrolled (issue #712)"
    end
  end

  # R12: inactive_with_covering_dates scenario records not_enrolled via verify!
  test "verify! records not_enrolled for inactive_with_covering_dates mock scenario" do
    with_tenant(TENANT) do
      referral = create_referral
      patient_identifier = referral.case.patient_identifier
      Corvid.adapter.seed_medicaid_eligibility_scenario(patient_identifier, :inactive_with_covering_dates)
      check = medicaid_check_for(referral)

      travel_to Time.zone.local(2026, 10, 10, 10, 0, 0) do
        assert check.verify!(date_of_service: Date.new(2026, 10, 10))
      end
      check.reload

      assert check.not_enrolled?,
             "service_active false from inactive_with_covering_dates must yield not_enrolled (issue #712)"
    end
  end

  private

  def snapshot_configuration
    {
      month_bounded: Corvid.configuration.month_bounded_eligibility_resource_types,
      placeholder_dates: Corvid.configuration.placeholder_coverage_end_dates,
      horizon_years: Corvid.configuration.placeholder_coverage_end_horizon_years
    }
  end

  def restore_configuration(snapshot)
    Corvid.configuration.month_bounded_eligibility_resource_types = snapshot[:month_bounded]
    Corvid.configuration.placeholder_coverage_end_dates = snapshot[:placeholder_dates]
    Corvid.configuration.placeholder_coverage_end_horizon_years = snapshot[:horizon_years]
  end

  def create_case
    Corvid::Case.create!(
      patient_identifier: PATIENT,
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_referral
    Corvid::PrcReferral.create!(case: create_case, referral_identifier: "ref_712_panel_#{SecureRandom.hex(3)}")
  end

  def medicaid_check_for(referral)
    Corvid::AlternateResourceCheck.create!(
      prc_referral: referral,
      resource_type: "medicaid"
    )
  end

  def verify_with_dos!(check, date_of_service)
    check.verify!(date_of_service: date_of_service)
  end

  def stub_verify(eligible:, coverage_start: nil, coverage_end: nil, echoed_inquiry: nil, **extra)
    Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
      dos = date_of_service || Date.current
      echo = echoed_inquiry || dos
      {
        eligible: eligible,
        coverage_start: coverage_start || Date.new(dos.year, dos.month, 1),
        coverage_end: coverage_end,
        date_of_service: echo,
        date_of_service_defaulted: date_of_service.nil?
      }.merge(extra)
    end
  end

  def stub_verify_omitting_date(eligible:, **extra)
    Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
      dos = date_of_service || Date.current
      {
        eligible: eligible,
        coverage_start: Date.new(dos.year, dos.month, 1),
        coverage_end: extra[:coverage_end],
        policy_token: extra[:policy_token]
      }.compact
    end
  end

  class RecordingMedicaidEligibilityGroupService
    attr_reader :calls

    def initialize
      @calls = []
    end

    def record!(check, coverage:, date_of_service:, **options)
      @calls << {
        check_id: check.id,
        status: check.status,
        checked_at: check.checked_at,
        coverage: coverage,
        date_of_service: date_of_service,
        options: options
      }
      check
    end
  end
end
