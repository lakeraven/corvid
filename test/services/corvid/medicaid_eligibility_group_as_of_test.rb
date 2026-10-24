# frozen_string_literal: true

require "test_helper"

# Issue #695: stated Medicaid eligibility groups respect adapter answer time (:as_of).
class Corvid::MedicaidEligibilityGroupAsOfTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TENANT = "tnt_test"
  DOS = Date.new(2026, 6, 15)
  PATIENT_ID = "pt_mcd_asof_001"
  AS_OF_NEWER = Time.utc(2026, 10, 10, 12, 0, 0)
  AS_OF_OLDER = Time.utc(2026, 10, 1, 12, 0, 0)

  setup do
    @adapter = Corvid.adapter
    @service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
    Corvid::PrcFacilityDictionary.reset!
  end

  test "record! keeps stated group when a later commit carries an older as_of" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: PATIENT_ID)
      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: AS_OF_NEWER),
        date_of_service: DOS
      )
      log_io = capture_rails_warn_log do
        result = @service.record!(
          check,
          coverage: stated_coverage("waiver_adult", as_of: AS_OF_OLDER),
          date_of_service: DOS
        )

        assert_equal "expansion_adult", result
      end

      assert_group_fields(check, "expansion_adult", "eligibility_response")
      assert_equal AS_OF_NEWER, check.reload.eligibility_group_as_of
      assert_no_unknown_answer_time_warning(log_io)
    end
  end

  test "record! overwrites stated group when incoming as_of is newer" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_002")
      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: AS_OF_OLDER),
        date_of_service: DOS
      )
      log_io = capture_rails_warn_log do
        result = @service.record!(
          check,
          coverage: stated_coverage("waiver_adult", as_of: AS_OF_NEWER),
          date_of_service: DOS
        )

        assert_equal "waiver_adult", result
      end

      assert_group_fields(check, "waiver_adult", "eligibility_response")
      assert_equal AS_OF_NEWER, check.reload.eligibility_group_as_of
      assert_no_unknown_answer_time_warning(log_io)
    end
  end

  test "record! overwrites stated group when incoming as_of equals stored as_of" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_003")
      shared = AS_OF_OLDER
      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: shared),
        date_of_service: DOS
      )
      log_io = capture_rails_warn_log do
        result = @service.record!(
          check,
          coverage: stated_coverage("waiver_adult", as_of: shared),
          date_of_service: DOS
        )

        assert_equal "waiver_adult", result
      end

      assert_group_fields(check, "waiver_adult", "eligibility_response")
      assert_equal shared, check.reload.eligibility_group_as_of
      assert_no_unknown_answer_time_warning(log_io)
    end
  end

  test "record! overwrites at equal microsecond precision when DB truncated stored sub-usec" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_009")
      stored_as_of = utc_with_subsecond_nsec(2026, 10, 10, 12, 0, 1_900)
      incoming_as_of = utc_with_subsecond_nsec(2026, 10, 10, 12, 0, 1_500)

      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: stored_as_of),
        date_of_service: DOS
      )
      assert_equal microsecond_floor(stored_as_of), check.reload.eligibility_group_as_of

      log_io = capture_rails_warn_log do
        result = @service.record!(
          check,
          coverage: stated_coverage("waiver_adult", as_of: incoming_as_of),
          date_of_service: DOS
        )
        assert_equal "waiver_adult", result
      end

      check.reload
      assert_group_fields(check, "waiver_adult", "eligibility_response")
      assert_equal microsecond_floor(incoming_as_of), check.eligibility_group_as_of
      assert_no_unknown_answer_time_warning(log_io)
    end
  end

  test "record! keeps stated group when incoming as_of is older at microsecond precision" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_010")
      stored_as_of = utc_with_subsecond_nsec(2026, 10, 10, 12, 0, 1_900)
      incoming_as_of = utc_with_subsecond_nsec(2026, 10, 10, 12, 0, 500)

      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: stored_as_of),
        date_of_service: DOS
      )
      assert_equal microsecond_floor(stored_as_of), check.reload.eligibility_group_as_of

      log_io = capture_rails_warn_log do
        result = @service.record!(
          check,
          coverage: stated_coverage("waiver_adult", as_of: incoming_as_of),
          date_of_service: DOS
        )
        assert_equal "expansion_adult", result
      end

      check.reload
      assert_group_fields(check, "expansion_adult", "eligibility_response")
      assert_equal microsecond_floor(stored_as_of), check.eligibility_group_as_of
      assert_no_unknown_answer_time_warning(log_io)
    end
  end

  test "record! last writer wins with nil incoming as_of and logs fixed warning once" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_004")
      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: AS_OF_NEWER),
        date_of_service: DOS
      )

      log_io = capture_rails_warn_log do
        result = @service.record!(
          check,
          coverage: stated_coverage("waiver_adult", as_of: nil),
          date_of_service: DOS
        )
        assert_equal "waiver_adult", result
      end

      check.reload
      assert_group_fields(check, "waiver_adult", "eligibility_response")
      assert_nil check.eligibility_group_as_of
      assert_unknown_answer_time_warning_logged(log_io, patient_id: PATIENT_ID)
    end
  end

  test "record! last writer wins when incoming coverage omits as_of and logs fixed warning" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_005")
      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: AS_OF_NEWER),
        date_of_service: DOS
      )

      log_io = capture_rails_warn_log do
        coverage = {
          state: "XA",
          eligibility_group: "other",
          eligibility_group_source: "eligibility_response"
        }
        result = @service.record!(check, coverage: coverage, date_of_service: DOS)
        assert_equal "other", result
      end

      check.reload
      assert_group_fields(check, "other", "eligibility_response")
      assert_nil check.eligibility_group_as_of
      assert_unknown_answer_time_warning_logged(log_io, patient_id: "pt_mcd_asof_005")
    end
  end

  test "record! writes when stored as_of is unknown and incoming as_of is known and logs warning" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_006")
      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: nil),
        date_of_service: DOS
      )
      assert_nil check.reload.eligibility_group_as_of

      log_io = capture_rails_warn_log do
        result = @service.record!(
          check,
          coverage: stated_coverage("waiver_adult", as_of: AS_OF_NEWER),
          date_of_service: DOS
        )
        assert_equal "waiver_adult", result
      end

      check.reload
      assert_group_fields(check, "waiver_adult", "eligibility_response")
      assert_equal AS_OF_NEWER, check.eligibility_group_as_of
      assert_unknown_answer_time_warning_logged(log_io, patient_id: "pt_mcd_asof_006")
    end
  end

  test "record_staff_entry! clears eligibility_group_as_of and still wins over stated as_of" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_007")
      @service.record!(
        check,
        coverage: stated_coverage("expansion_adult", as_of: AS_OF_NEWER),
        date_of_service: DOS
      )
      assert_equal AS_OF_NEWER, check.reload.eligibility_group_as_of

      @service.record_staff_entry!(check, eligibility_group: "other")
      check.reload

      assert_equal "other", check.eligibility_group
      assert_equal "staff_entry", check.eligibility_group_source
      assert_nil check.eligibility_group_as_of
    end
  end

  test "record! inference leaves eligibility_group_as_of nil" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_asof_008", dob: Date.new(1996, 6, 15))
      result = @service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
      assert_nil check.reload.eligibility_group_as_of
    end
  end

  test "verify! keeps first stated group when second verify sees older get_coverages as_of" do
    with_tenant(TENANT) do
      register_patient!(patient_id: PATIENT_ID, dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response",
        as_of: AS_OF_NEWER
      )
      check = create_medicaid_check!
      stub_verify_eligibility!(eligible: true, policy_token: "TEST-POLICY-695")

      assert check.verify!
      check.reload
      assert_equal "expansion_adult", check.eligibility_group
      assert_equal AS_OF_NEWER, check.eligibility_group_as_of

      older_row = [
        {
          coverage_type: "medicaid",
          eligible: true,
          state: "XA",
          eligibility_group: "waiver_adult",
          eligibility_group_source: "state_case_data",
          as_of: AS_OF_OLDER
        }
      ]
      sequencing = SequencingGetCoveragesAdapterDelegate.new(@adapter, patient_id: PATIENT_ID, sequences: [ older_row ])

      travel_to Time.zone.local(2026, 6, 1, 10, 0, 0) do
        with_adapter(sequencing) { assert check.verify! }
      end
      check.reload

      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "eligibility_response", check.eligibility_group_source
      assert_equal AS_OF_NEWER, check.eligibility_group_as_of
    end
  end

  class SequencingGetCoveragesAdapterDelegate
    def initialize(inner, patient_id:, sequences:)
      @inner = inner
      @patient_id = patient_id.to_s
      @sequences = sequences.dup
    end

    def get_coverages(patient_identifier)
      if patient_identifier.to_s == @patient_id && @sequences.any?
        return @sequences.shift
      end

      @inner.get_coverages(patient_identifier)
    end

    def verify_eligibility(patient_identifier, resource_type)
      @inner.verify_eligibility(patient_identifier, resource_type)
    end

    def add_coverage(patient_identifier, attrs = {}, **extra)
      @inner.add_coverage(patient_identifier, attrs, **extra)
    end

    def add_patient(patient_identifier, **attrs)
      @inner.add_patient(patient_identifier, **attrs)
    end

    def find_patient(patient_identifier)
      @inner.find_patient(patient_identifier)
    end

    def respond_to_missing?(method, include_private = false)
      @inner.respond_to?(method, include_private) || super
    end

    def method_missing(method, *args, **kwargs, &block)
      @inner.public_send(method, *args, **kwargs, &block)
    end
  end

  private

  def stated_coverage(group, source: "eligibility_response", as_of:)
    {
      state: "XA",
      eligibility_group: group,
      eligibility_group_source: source,
      as_of: as_of
    }
  end

  def medicaid_check_for(patient_id:, dob: Date.new(1996, 6, 15))
    @adapter.add_patient(
      patient_id,
      display_name: "TEST,PATIENT ASOF",
      dob: dob,
      sex: "F",
      ssn_last4: "0000"
    )
    Corvid::AlternateResourceCheck.create!(
      prc_referral: create_referral(patient_id: patient_id),
      resource_type: "medicaid",
      status: "checking"
    )
  end

  def create_referral(patient_id:)
    kase = Corvid::Case.create!(
      patient_identifier: patient_id,
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
    Corvid::PrcReferral.create!(case: kase, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_medicaid_check!
    Corvid::AlternateResourceCheck.create!(
      prc_referral: create_referral(patient_id: PATIENT_ID),
      resource_type: "medicaid",
      status: "not_checked"
    )
  end

  def register_patient!(patient_id:, dob:)
    @adapter.add_patient(
      patient_id,
      display_name: "TEST,PATIENT ASOF",
      dob: dob,
      sex: "F",
      ssn_last4: "0000"
    )
  end

  def stub_verify_eligibility!(eligible:, policy_token:)
    @adapter.define_singleton_method(:verify_eligibility) do |_patient_identifier, _resource_type|
      {
        eligible: eligible,
        policy_token: policy_token,
        coverage_start: nil,
        coverage_end: nil,
        renewal_date: nil
      }
    end
  end

  def with_adapter(adapter)
    original = Corvid.adapter
    Corvid.configure { |c| c.adapter = adapter }
    yield
  ensure
    Corvid.configure { |c| c.adapter = original }
  end

  def assert_group_fields(check, group, source)
    check.reload
    assert_equal group, check.eligibility_group
    assert_equal source, check.eligibility_group_source
    refute_nil check.eligibility_group_set_at unless group.nil?
  end

  def capture_rails_warn_log
    log_io = StringIO.new
    original_logger = Rails.logger
    logger = ActiveSupport::Logger.new(log_io)
    logger.level = ::Logger::WARN
    Rails.logger = logger
    yield
    log_io
  ensure
    Rails.logger = original_logger if original_logger
  end

  def assert_unknown_answer_time_warning_logged(log_io, patient_id:)
    message = Corvid::MedicaidEligibilityGroupService::UNKNOWN_ANSWER_TIME_WARNING
    logged = log_io.string
    assert_equal 1, logged.scan(message).size, "expected warning logged exactly once"
    assert_includes logged, message
    refute_includes logged, patient_id
    refute_match(/ref_[0-9a-f]+/i, logged)
  end

  def assert_no_unknown_answer_time_warning(log_io)
    message = Corvid::MedicaidEligibilityGroupService::UNKNOWN_ANSWER_TIME_WARNING
    refute_includes log_io.string, message
  end

  def utc_with_subsecond_nsec(year, month, day, hour, min, nsec)
    Time.utc(year, month, day, hour, min, Rational(nsec, 1_000_000_000))
  end

  def microsecond_floor(time)
    Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec, time.usec)
  end
end
