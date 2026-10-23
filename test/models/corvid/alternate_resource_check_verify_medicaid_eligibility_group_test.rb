# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Issue #670: verify! records Medicaid eligibility group via MedicaidEligibilityGroupService#record!
class Corvid::AlternateResourceCheckVerifyMedicaidEligibilityGroupTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TENANT = "tnt_test"
  PATIENT_ID = "pt_mcd_verify_670"
  VERIFY_ELIGIBILITY_GROUP_WARNING =
    "medicaid eligibility group could not be recorded during verification"

  setup do
    @adapter = Corvid.adapter
  end

  test "verify! calls MedicaidEligibilityGroupService#record! after eligibility status is saved" do
    with_tenant(TENANT) do
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new

      Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
        travel_to Time.zone.local(2026, 4, 2, 10, 0, 0) do
          assert check.verify!
        end
      end

      assert_equal 1, recorder.calls.size
      call = recorder.calls.first
      assert_equal "enrolled", call[:status]
      assert_not_nil call[:checked_at]
      assert_equal check.id, call[:check_id]
    end
  end

  test "verify! does not call MedicaidEligibilityGroupService#record! for non-medicaid checks" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral,
        resource_type: "medicare_a",
        status: "not_checked"
      )
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new

      Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
        assert check.verify!
      end

      assert_empty recorder.calls
    end
  end

  test "verify! passes medicaid get_coverages entry as coverage when exactly one matches resource_type" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicare_a",
        eligible: true,
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "eligibility_response"
      )
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new

      Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
        assert check.verify!
      end

      call = sole_record_call(recorder)
      coverage = call[:coverage]
      assert_equal "expansion_adult", coverage[:eligibility_group]
      assert_equal "eligibility_response", coverage[:eligibility_group_source]
      assert_equal "XA", coverage[:state]
    end
  end

  test "verify! records stated expansion_adult when single medicaid coverage states a group" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload

      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "eligibility_response", check.eligibility_group_source
      assert_not_nil check.eligibility_group_set_at
    end
  end

  test "verify! passes empty coverage for inference when no get_coverages entry matches medicaid" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicare_a",
        eligible: true,
        state: "XA",
        plan_name: "TEST REGULAR PLAN"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new

      Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
        assert check.verify!
      end

      call = sole_record_call(recorder)
      assert_empty call[:coverage]
    end
  end

  test "verify! records unknown when no get_coverages entry matches medicaid" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicare_a",
        eligible: true,
        state: "XA",
        plan_name: "TEST REGULAR PLAN"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload

      assert_equal "unknown", check.eligibility_group
      assert_equal "inferred", check.eligibility_group_source
      assert_not_nil check.eligibility_group_set_at
    end
  end

  test "verify! passes empty coverage for inference when more than one medicaid get_coverages entry exists" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new

      Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
        assert check.verify!
      end

      call = sole_record_call(recorder)
      assert_empty call[:coverage]
    end
  end

  test "verify! records unknown when more than one medicaid get_coverages entry exists" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload

      assert_equal "unknown", check.eligibility_group
      assert_equal "inferred", check.eligibility_group_source
      assert_not_nil check.eligibility_group_set_at
    end
  end

  test "verify! passes checked_at date as date_of_service when referral has no service date" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        plan_name: "TEST REGULAR PLAN"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new
      verification_instant = Time.zone.local(2025, 6, 1, 12, 0, 0)

      Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
        travel_to verification_instant do
          assert check.verify!
        end
      end

      assert_equal Date.new(2025, 6, 1), sole_record_call(recorder)[:date_of_service]
    end
  end

  test "verify! passes referral service date as date_of_service when present" do
    skip "PrcReferral has no service_date column" unless Corvid::PrcReferral.column_names.include?("service_date")

    service_date = Date.new(2025, 8, 15)
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        plan_name: "TEST REGULAR PLAN"
      )
      referral = create_referral
      assign_referral_service_date!(referral, service_date)
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: "medicaid",
        status: "not_checked"
      )
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new

      Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
        travel_to Time.zone.local(2026, 1, 1, 9, 0, 0) do
          assert check.verify!
        end
      end

      assert_equal service_date, sole_record_call(recorder)[:date_of_service]
      refute_equal Date.new(2026, 1, 1), sole_record_call(recorder)[:date_of_service]
    end
  end

  test "verify! does not overwrite staff_entry eligibility group" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter).record_staff_entry!(
        check,
        eligibility_group: "waiver_adult"
      )
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload

      assert_equal "waiver_adult", check.eligibility_group
      assert_equal "staff_entry", check.eligibility_group_source

      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: false,
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "eligibility_response"
      )

      travel_to Time.zone.local(2026, 6, 1, 10, 0, 0) do
        assert check.verify!
      end
      check.reload

      assert_equal "waiver_adult", check.eligibility_group
      assert_equal "staff_entry", check.eligibility_group_source
    end
  end

  test "verify! completes without calling record! when get_coverages returns nil" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new

      assert check.verify!
      check.reload
      prior_group = check.eligibility_group
      prior_source = check.eligibility_group_source
      prior_set_at = check.eligibility_group_set_at
      assert_equal "expansion_adult", prior_group
      recorder.calls.clear

      broken = FixedGetCoveragesReturnAdapterDelegate.new(@adapter, get_coverages_return: nil)
      log_io = capture_rails_warn_log do
        Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
          with_adapter(broken) do
            travel_to Time.zone.local(2026, 2, 1, 10, 0, 0) do
              assert check.verify!
            end
          end
        end
      end

      check.reload
      assert_equal "enrolled", check.status
      assert_not_nil check.checked_at
      assert_empty recorder.calls
      assert_equal prior_group, check.eligibility_group
      assert_equal prior_source, check.eligibility_group_source
      assert_equal prior_set_at, check.eligibility_group_set_at
      assert_warning_logged_without_phi(log_io, PATIENT_ID)
    end
  end

  test "verify! completes without calling record! when get_coverages returns non-array" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      recorder = RecordingMedicaidEligibilityGroupService.new
      broken = FixedGetCoveragesReturnAdapterDelegate.new(@adapter, get_coverages_return: { status: "no_answer" })

      log_io = capture_rails_warn_log do
        Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { recorder }) do
          with_adapter(broken) { assert check.verify! }
        end
      end

      check.reload
      assert_equal "enrolled", check.status
      assert_not_nil check.checked_at
      assert_empty recorder.calls
      assert_nil check.eligibility_group
      assert_nil check.eligibility_group_source
      assert_nil check.eligibility_group_set_at
      assert_warning_logged_without_phi(log_io, PATIENT_ID)
    end
  end

  test "verify! re-infers when re-verification has one medicaid coverage with nil group and prior group was stated" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload
      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "eligibility_response", check.eligibility_group_source
      first_set_at = check.eligibility_group_set_at

      nil_group_row = [
        {
          coverage_type: "medicaid",
          eligible: true,
          state: "XA",
          eligibility_group: nil,
          plan_name: "TEST REGULAR PLAN"
        }
      ]
      sequencing = SequencingGetCoveragesAdapterDelegate.new(@adapter, patient_id: PATIENT_ID, sequences: [ nil_group_row ])

      travel_to Time.zone.local(2026, 6, 1, 10, 0, 0) do
        with_adapter(sequencing) { assert check.verify! }
      end
      check.reload

      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "inferred", check.eligibility_group_source
      refute_equal first_set_at, check.eligibility_group_set_at
    end
  end

  test "verify! re-infers unknown when re-verification has one medicaid coverage with unknown group in ZZ and prior group was stated" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload
      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "eligibility_response", check.eligibility_group_source

      unknown_row = [
        {
          coverage_type: "medicaid",
          eligible: true,
          state: "ZZ",
          eligibility_group: "unknown",
          eligibility_group_source: "eligibility_response"
        }
      ]
      sequencing = SequencingGetCoveragesAdapterDelegate.new(@adapter, patient_id: PATIENT_ID, sequences: [ unknown_row ])

      travel_to Time.zone.local(2026, 6, 1, 11, 0, 0) do
        with_adapter(sequencing) { assert check.verify! }
      end
      check.reload

      assert_equal "unknown", check.eligibility_group
      assert_equal "inferred", check.eligibility_group_source
    end
  end

  test "verify! still records stated group when re-verification has one medicaid coverage that states a real group" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload
      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "eligibility_response", check.eligibility_group_source

      waiver_row = [
        {
          coverage_type: "medicaid",
          eligible: true,
          state: "XB",
          eligibility_group: "waiver_adult",
          eligibility_group_source: "state_case_data",
          plan_name: "TEST SYNTHETIC WAIVER PLAN"
        }
      ]
      sequencing = SequencingGetCoveragesAdapterDelegate.new(@adapter, patient_id: PATIENT_ID, sequences: [ waiver_row ])

      travel_to Time.zone.local(2026, 6, 1, 12, 0, 0) do
        with_adapter(sequencing) { assert check.verify! }
      end
      check.reload

      assert_equal "waiver_adult", check.eligibility_group
      assert_equal "state_case_data", check.eligibility_group_source
    end
  end

  test "verify! does not overwrite newer stated group when concurrent write happens before superseding record!" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload
      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "eligibility_response", check.eligibility_group_source

      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: false,
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "eligibility_response"
      )

      inner_service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
      concurrent_before_supersede = ConcurrentWriteBeforeSupersedeRecordService.new(inner_service)

      travel_to Time.zone.local(2026, 6, 1, 13, 0, 0) do
        Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { concurrent_before_supersede }) do
          assert check.verify!
        end
      end
      check.reload

      assert_equal "waiver_adult", check.eligibility_group
      assert_equal "state_case_data", check.eligibility_group_source
    end
  end

  test "verify! does not overwrite newer stated group written during get_coverages" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload
      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "eligibility_response", check.eligibility_group_source

      nil_group_row = [
        {
          coverage_type: "medicaid",
          eligible: true,
          state: "XA",
          eligibility_group: nil
        }
      ]
      writing = WriteDuringGetCoveragesAdapterDelegate.new(
        @adapter,
        check_id: check.id,
        rows: nil_group_row
      )

      travel_to Time.zone.local(2026, 6, 1, 14, 0, 0) do
        with_adapter(writing) { assert check.verify! }
      end
      check.reload

      assert_equal "waiver_adult", check.eligibility_group
      assert_equal "state_case_data", check.eligibility_group_source
    end
  end

  test "verify! re-infers when re-verification has ambiguous medicaid coverage and prior group was stated" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload
      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "eligibility_response", check.eligibility_group_source
      first_set_at = check.eligibility_group_set_at

      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: false,
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "eligibility_response"
      )

      travel_to Time.zone.local(2026, 6, 1, 10, 0, 0) do
        assert check.verify!
      end
      check.reload

      assert_equal "unknown", check.eligibility_group
      assert_equal "inferred", check.eligibility_group_source
      assert_operator check.eligibility_group_set_at, :>=, Time.zone.local(2026, 6, 1, 10, 0, 0)
      refute_equal first_set_at, check.eligibility_group_set_at
    end
  end

  test "verify! re-infers when re-verification has ambiguous medicaid coverage and prior group was inferred" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        plan_name: "TEST REGULAR PLAN"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")

      assert check.verify!
      check.reload
      assert_equal "expansion_adult", check.eligibility_group
      assert_equal "inferred", check.eligibility_group_source
      first_set_at = check.eligibility_group_set_at

      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "eligibility_response"
      )

      travel_to Time.zone.local(2026, 6, 1, 10, 0, 0) do
        assert check.verify!
      end
      check.reload

      assert_equal "unknown", check.eligibility_group
      assert_equal "inferred", check.eligibility_group_source
      assert_operator check.eligibility_group_set_at, :>=, Time.zone.local(2026, 6, 1, 10, 0, 0)
      refute_equal first_set_at, check.eligibility_group_set_at
    end
  end

  test "verify! completes and logs fixed warning when get_coverages raises" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      raising = RaisingAdapterDelegate.new(@adapter, get_coverages_raises: StandardError)

      log_io = capture_rails_warn_log do
        with_adapter(raising) { assert check.verify! }
      end

      check.reload
      assert_equal "enrolled", check.status
      assert_not_nil check.checked_at
      assert_nil check.eligibility_group
      assert_warning_logged_without_phi(log_io, PATIENT_ID)
    end
  end

  test "verify! completes and logs fixed warning when find_patient raises during inference" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        plan_name: "TEST REGULAR PLAN"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      raising = RaisingAdapterDelegate.new(@adapter, find_patient_raises: Timeout::Error)

      log_io = capture_rails_warn_log do
        with_adapter(raising) { assert check.verify! }
      end

      check.reload
      assert_equal "enrolled", check.status
      assert_not_nil check.checked_at
      assert_nil check.eligibility_group
      assert_warning_logged_without_phi(log_io, PATIENT_ID)
    end
  end

  test "verify! completes and logs fixed warning when MedicaidEligibilityGroupService#record! raises" do
    with_tenant(TENANT) do
      register_patient(dob: Date.new(1996, 6, 15))
      @adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      )
      check = create_medicaid_check!
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-670")
      raising_service = RaisingMedicaidEligibilityGroupService.new

      log_io = capture_rails_warn_log do
        Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { raising_service }) do
          assert check.verify!
        end
      end

      check.reload
      assert_equal "enrolled", check.status
      assert_not_nil check.checked_at
      assert_nil check.eligibility_group
      assert_warning_logged_without_phi(log_io, PATIENT_ID)
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

  class WriteDuringGetCoveragesAdapterDelegate
    def initialize(inner, check_id:, rows:)
      @inner = inner
      @check_id = check_id
      @rows = rows
    end

    def get_coverages(_patient_identifier)
      Corvid::AlternateResourceCheck.where(id: @check_id).update_all(
        eligibility_group: "waiver_adult",
        eligibility_group_source: "state_case_data",
        eligibility_group_set_at: Time.current + 1.second
      )
      @rows
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

  class ConcurrentWriteBeforeSupersedeRecordService
    def initialize(inner)
      @inner = inner
    end

    def record!(check, coverage:, date_of_service:, supersede_stated: false)
      if supersede_stated
        @inner.record!(
          check,
          coverage: {
            state: "XA",
            eligibility_group: "waiver_adult",
            eligibility_group_source: "state_case_data"
          },
          date_of_service: date_of_service
        )
      end

      @inner.record!(
        check,
        coverage: coverage,
        date_of_service: date_of_service,
        supersede_stated: supersede_stated
      )
    end

    def record_staff_entry!(check, eligibility_group:)
      @inner.record_staff_entry!(check, eligibility_group: eligibility_group)
    end
  end

  class RecordingMedicaidEligibilityGroupService
    attr_reader :calls

    def initialize(**)
      @calls = []
    end

    def record!(check, coverage:, date_of_service:)
      check.reload
      @calls << {
        check_id: check.id,
        status: check.status,
        checked_at: check.checked_at,
        coverage: coverage_hash(coverage),
        date_of_service: date_of_service
      }
      nil
    end

    private

    def coverage_hash(coverage)
      return {} unless coverage.is_a?(Hash)

      coverage
    end
  end

  class RaisingMedicaidEligibilityGroupService
    def record!(*)
      raise StandardError, "synthetic record failure"
    end
  end

  class FixedGetCoveragesReturnAdapterDelegate
    def initialize(inner, get_coverages_return:)
      @inner = inner
      @get_coverages_return = get_coverages_return
    end

    def get_coverages(_patient_identifier)
      @get_coverages_return
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

  class RaisingAdapterDelegate
    def initialize(inner, get_coverages_raises: nil, find_patient_raises: nil)
      @inner = inner
      @get_coverages_raises = get_coverages_raises
      @find_patient_raises = find_patient_raises
    end

    def get_coverages(patient_identifier)
      raise @get_coverages_raises if @get_coverages_raises

      @inner.get_coverages(patient_identifier)
    end

    def find_patient(patient_identifier)
      raise @find_patient_raises if @find_patient_raises

      @inner.find_patient(patient_identifier)
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

    def respond_to_missing?(method, include_private = false)
      @inner.respond_to?(method, include_private) || super
    end

    def method_missing(method, *args, **kwargs, &block)
      @inner.public_send(method, *args, **kwargs, &block)
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: PATIENT_ID,
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_referral
    Corvid::PrcReferral.create!(case: create_case, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_medicaid_check!
    Corvid::AlternateResourceCheck.create!(
      prc_referral: create_referral,
      resource_type: "medicaid",
      status: "not_checked"
    )
  end

  def register_patient(dob:)
    @adapter.add_patient(
      PATIENT_ID,
      display_name: "TEST,PATIENT 670",
      dob: dob,
      sex: "F",
      ssn_last4: "0000"
    )
  end

  def stub_verify_eligibility(eligible:, policy_token: nil)
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

  def assign_referral_service_date!(referral, service_date)
    referral.update!(service_date: service_date)
  end

  def with_adapter(adapter)
    original = Corvid.adapter
    Corvid.configure { |c| c.adapter = adapter }
    yield
  ensure
    Corvid.configure { |c| c.adapter = original }
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

  def assert_warning_logged_without_phi(log_io, patient_identifier)
    message = expected_verify_warning_message
    assert_includes log_io.string, message
    refute_includes log_io.string, patient_identifier
  end

  def sole_record_call(recorder)
    assert_equal 1, recorder.calls.size, "expected verify! to call MedicaidEligibilityGroupService#record! once"
    recorder.calls.first
  end

  def expected_verify_warning_message
    if Corvid::AlternateResourceCheck.const_defined?(:VERIFY_MEDICAID_ELIGIBILITY_GROUP_WARNING)
      Corvid::AlternateResourceCheck::VERIFY_MEDICAID_ELIGIBILITY_GROUP_WARNING
    else
      VERIFY_ELIGIBILITY_GROUP_WARNING
    end
  end
end
