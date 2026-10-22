# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class Corvid::MedicaidEligibilityGroupServiceTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"
  DOS = Date.new(2026, 6, 15)

  setup do
    @adapter = Corvid.adapter
    @service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
    Corvid::PrcFacilityDictionary.reset!
  end

  # -- Inference: expansion state XA -------------------------------------------------

  test "record! infers expansion_adult for XA member age 30 on date of service" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_001", dob: Date.new(1996, 6, 15))
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! infers other for XA member age 70 on date of service" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_002", dob: Date.new(1956, 6, 15))
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "other", result
      assert_group_fields(check, "other", "inferred")
    end
  end

  test "record! infers other for XA member age 18 on date of service" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_003", dob: Date.new(2007, 6, 16))
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "other", result
      assert_group_fields(check, "other", "inferred")
    end
  end

  # -- Inference: waiver state XB ----------------------------------------------------

  test "record! infers waiver_adult for XB age 30 with synthetic waiver plan name" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_004", dob: Date.new(1996, 6, 15))
      result = record!(check, state: "XB", plan_name: "TEST SYNTHETIC WAIVER PLAN")

      assert_equal "waiver_adult", result
      assert_group_fields(check, "waiver_adult", "inferred")
    end
  end

  test "record! infers unknown for XB age 30 with non-waiver plan" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_005", dob: Date.new(1996, 6, 15))
      result = record!(check, state: "XB", plan_name: "TEST REGULAR PLAN")

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  test "record! infers unknown for XB age 70 with waiver plan (ambiguous age)" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_006", dob: Date.new(1956, 6, 15))
      result = record!(check, state: "XB", plan_name: "TEST SYNTHETIC WAIVER PLAN")

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  test "record! infers unknown for XB age 30 with blank plan description" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_007", dob: Date.new(1996, 6, 15))
      result = record!(check, state: "XB", plan_name: "   ")

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  # -- Inference: unknown branches ---------------------------------------------------

  test "record! infers unknown for unconfigured state ZZ" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_008", dob: Date.new(1996, 6, 15))
      result = record!(check, state: "ZZ", plan_name: "TEST REGULAR PLAN")

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  test "record! infers unknown when coverage omits state" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_009", dob: Date.new(1996, 6, 15))
      result = record!(check, plan_name: "TEST REGULAR PLAN")

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  test "record! infers unknown when coverage omits state even if referral facility maps to XA" do
    with_tenant(TENANT) do
      Corvid::PrcFacilityDictionary.register(
        "fac_mcd_xa_646",
        name: "Synthetic XA facility",
        state: "XA"
      )
      check = medicaid_check_for(
        patient_id: "pt_mcd_fac_state_001",
        dob: Date.new(1996, 6, 15),
        facility_identifier: "fac_mcd_xa_646"
      )
      result = record!(check, plan_name: "TEST REGULAR PLAN")

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  test "record! infers unknown when patient is not found in adapter" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_missing", register_patient: false)
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  test "record! infers unknown when adapter patient has no date of birth" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_010", dob: nil)
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  test "record! infers unknown when date_of_service is nil" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_011", dob: Date.new(1996, 6, 15))
      result = @service.record!(check, coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" }, date_of_service: nil)

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  # -- Age boundary cases --------------------------------------------------------------

  test "record! treats member as 19 years old on exact 19th birthday in XA as expansion_adult" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_012", dob: Date.new(2007, 6, 15))
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! treats member as 64 years old on last day of that age in XA as expansion_adult" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_013", dob: Date.new(1961, 6, 16))
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! treats day before 19th birthday in XA as other" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_014", dob: Date.new(2007, 6, 16))
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN", date_of_service: Date.new(2026, 6, 15))

      assert_equal "other", result
      assert_group_fields(check, "other", "inferred")
    end
  end

  test "record! treats 65th birthday in XA as other" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_015", dob: Date.new(1961, 6, 15))
      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "other", result
      assert_group_fields(check, "other", "inferred")
    end
  end

  test "record! counts Feb 29 birthday on Mar 1 in non-leap year for age" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_016", dob: Date.new(2000, 2, 29))
      result = record!(
        check,
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        date_of_service: Date.new(2025, 3, 1)
      )

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  # -- Stated group --------------------------------------------------------------------

  test "record! persists stated eligibility_group with explicit eligibility_response source" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_017", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "waiver_adult",
        eligibility_group_source: "state_case_data"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "waiver_adult", result
      assert_group_fields(check, "waiver_adult", "state_case_data")
    end
  end

  test "record! defaults stated source to eligibility_response when omitted" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_018", dob: Date.new(1996, 6, 15))
      coverage = { state: "XA", eligibility_group: "other" }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "other", result
      assert_group_fields(check, "other", "eligibility_response")
    end
  end

  test "record! accepts symbol stated eligibility_group and registration source" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_019", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        eligibility_group: :expansion_adult,
        eligibility_group_source: :registration
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "registration")
    end
  end

  test "record! ignores unrecognised stated eligibility_group and infers" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_020", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "not_a_real_group",
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  # -- Precedence ----------------------------------------------------------------------

  test "record! stated group overwrites a prior inferred group" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_021", dob: Date.new(1996, 6, 15))
      record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")
      assert_group_fields(check, "expansion_adult", "inferred")

      coverage = { state: "XA", eligibility_group: "other", eligibility_group_source: "eligibility_response" }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "other", result
      assert_group_fields(check, "other", "eligibility_response")
    end
  end

  test "record! inference does not overwrite a prior stated group" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_022", dob: Date.new(1996, 6, 15))
      stated = {
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "state_case_data"
      }
      @service.record!(check, coverage: stated, date_of_service: DOS)

      record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")
      check.reload
      assert_equal "other", check.eligibility_group
      assert_equal "state_case_data", check.eligibility_group_source
    end
  end

  test "record! inference overwrites a prior inferred group" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_023", dob: Date.new(1996, 6, 15))
      record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")
      assert_group_fields(check, "expansion_adult", "inferred")

      record!(check, state: "XA", plan_name: "TEST REGULAR PLAN", patient_dob: Date.new(1956, 6, 15))
      assert_group_fields(check, "other", "inferred")
    end
  end

  test "record! does not overwrite staff_entry with inferred group" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_024", dob: Date.new(1996, 6, 15))
      @service.record_staff_entry!(check, eligibility_group: "waiver_adult")

      record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")
      check.reload
      assert_equal "waiver_adult", check.eligibility_group
      assert_equal "staff_entry", check.eligibility_group_source
    end
  end

  test "record! does not overwrite staff_entry with stated group" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_025", dob: Date.new(1996, 6, 15))
      @service.record_staff_entry!(check, eligibility_group: "other")

      coverage = { state: "XA", eligibility_group: "expansion_adult", eligibility_group_source: "registration" }
      @service.record!(check, coverage: coverage, date_of_service: DOS)
      check.reload
      assert_equal "other", check.eligibility_group
      assert_equal "staff_entry", check.eligibility_group_source
    end
  end

  # -- record_staff_entry! -------------------------------------------------------------

  test "record_staff_entry! sets staff_entry source for valid medicaid check" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_026", dob: Date.new(1996, 6, 15))
      result = @service.record_staff_entry!(check, eligibility_group: "expansion_adult")

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "staff_entry")
    end
  end

  test "record_staff_entry! raises for non-medicaid check" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral(patient_id: "pt_mcd_027"),
        resource_type: "medicare_a",
        status: "checking"
      )

      assert_raises(ArgumentError) do
        @service.record_staff_entry!(check, eligibility_group: "other")
      end
    end
  end

  test "record_staff_entry! raises for invalid eligibility_group value" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_028", dob: Date.new(1996, 6, 15))

      assert_raises(ArgumentError) do
        @service.record_staff_entry!(check, eligibility_group: "invalid_group")
      end
    end
  end

  # -- Non-medicaid / timestamps -----------------------------------------------------

  test "record! returns nil and leaves non-medicaid check unchanged" do
    with_tenant(TENANT) do
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral(patient_id: "pt_mcd_029"),
        resource_type: "medicare_a",
        status: "checking"
      )

      counting = CountingAdapterDelegate.new(@adapter, find_patient_raises: Timeout::Error)
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: counting)

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_nil result
      assert_equal 0, counting.find_patient_calls
      check.reload
      assert_nil check.eligibility_group
      assert_nil check.eligibility_group_source
      assert_nil check.eligibility_group_set_at
    end
  end

  test "record! sets eligibility_group_set_at to current time" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_030", dob: Date.new(1996, 6, 15))

      travel_to Time.zone.parse("2026-06-15 14:30:00 UTC") do
        record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")
        check.reload
        assert_in_delta Time.current, check.eligibility_group_set_at, 1.second
      end
    end
  end

  # -- Issue #646 P1: stale in-memory check must not overwrite persisted staff_entry -

  test "record! on stale check does not overwrite staff_entry with inference" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stale_001", dob: Date.new(1996, 6, 15))
      job_copy = stale_in_memory_check_after(check) do
        @service.record_staff_entry!(check, eligibility_group: "other")
      end

      @service.record!(
        job_copy,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_group_fields(check, "other", "staff_entry")
    end
  end

  test "record! on stale check with stated coverage does not overwrite staff_entry" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stale_002", dob: Date.new(1996, 6, 15))
      stated_coverage = {
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "registration"
      }
      @service.record!(check, coverage: stated_coverage, date_of_service: DOS)
      job_copy = stale_in_memory_check_after(check) do
        @service.record_staff_entry!(check, eligibility_group: "other")
      end

      @service.record!(job_copy, coverage: stated_coverage, date_of_service: DOS)

      assert_group_fields(check, "other", "staff_entry")
    end
  end

  # -- Issue #646 P2: adapter may only state eligibility_response, state_case_data, registration

  test "record! maps disallowed eligibility_group_source staff_entry to eligibility_response" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_src_001", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "staff_entry"
      }

      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "other", result
      assert_group_fields(check, "other", "eligibility_response")
    end
  end

  test "record! replaces adapter-normalized group when registration source is stated later" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_src_002", dob: Date.new(1996, 6, 15))
      first = {
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "staff_entry"
      }
      @service.record!(check, coverage: first, date_of_service: DOS)
      assert_group_fields(check, "other", "eligibility_response")

      second = {
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: second, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "registration")
    end
  end

  test "record! maps 271 eligibility_group_source to eligibility_response over inferred group" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_src_003", dob: Date.new(1996, 6, 15))
      record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")
      assert_group_fields(check, "expansion_adult", "inferred")

      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "waiver_adult",
        eligibility_group_source: "271"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "waiver_adult", result
      assert_group_fields(check, "waiver_adult", "eligibility_response")
    end
  end

  # -- Issue #646 P3: nil, blank, or unknown eligibility_group is not a statement ------

  test "record! infers when eligibility_group key is present but nil" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_nil_grp_001", dob: Date.new(1996, 6, 15))
      coverage = { eligibility_group: nil, state: "XA", plan_name: "TEST REGULAR PLAN" }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! infers when eligibility_group is blank string" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_nil_grp_002", dob: Date.new(1996, 6, 15))
      coverage = { eligibility_group: "", state: "XA", plan_name: "TEST REGULAR PLAN" }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! infers expansion_adult when stated eligibility_group is unknown string" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_unk_stmt_001", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "unknown",
        eligibility_group_source: "eligibility_response"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! infers expansion_adult when stated eligibility_group is unknown symbol" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_unk_stmt_002", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: :unknown,
        eligibility_group_source: "eligibility_response"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! does not overwrite registration-sourced group when coverage states unknown" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_unk_stmt_003", dob: Date.new(1996, 6, 15))
      stated = {
        state: "XA",
        eligibility_group: "waiver_adult",
        eligibility_group_source: "registration"
      }
      @service.record!(check, coverage: stated, date_of_service: DOS)

      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "unknown",
        eligibility_group_source: "eligibility_response"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "waiver_adult", result
      assert_group_fields(check, "waiver_adult", "registration")
    end
  end

  test "record! does not overwrite staff_entry when coverage states unknown" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_unk_stmt_004", dob: Date.new(1996, 6, 15))
      @service.record_staff_entry!(check, eligibility_group: "other")

      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "unknown",
        eligibility_group_source: "eligibility_response"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "other", result
      assert_group_fields(check, "other", "staff_entry")
    end
  end

  test "record! inference replaces prior unknown recorded with eligibility_response source" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_unk_stmt_005", dob: Date.new(1996, 6, 15))
      check.update_columns(
        eligibility_group: "unknown",
        eligibility_group_source: "eligibility_response",
        eligibility_group_set_at: Time.current
      )
      assert_group_fields(check, "unknown", "eligibility_response")

      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! does not replace registration-sourced group when eligibility_group is nil" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_nil_grp_003", dob: Date.new(1996, 6, 15))
      stated = {
        state: "XA",
        eligibility_group: "waiver_adult",
        eligibility_group_source: "registration"
      }
      @service.record!(check, coverage: stated, date_of_service: DOS)

      coverage = { eligibility_group: nil, state: "XA", plan_name: "TEST REGULAR PLAN" }
      @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_group_fields(check, "waiver_adult", "registration")
    end
  end

  # -- Issue #646 P4: ADR 0002 tenant scoping on writes --------------------------------

  test "record! from another tenant does not write stated group" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_tenant_001", dob: Date.new(1996, 6, 15))
    end

    result = nil
    with_tenant(OTHER_TENANT) do
      coverage = {
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)
    end

    assert_nil result
    assert_group_fields_under_tenant(check, TENANT, nil, nil)
  end

  test "record! from another tenant does not write inferred group" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_tenant_002", dob: Date.new(1996, 6, 15))
    end

    result = nil
    with_tenant(OTHER_TENANT) do
      result = @service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )
    end

    assert_nil result
    assert_group_fields_under_tenant(check, TENANT, nil, nil)
  end

  test "record_staff_entry! from another tenant raises and does not write" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_tenant_003", dob: Date.new(1996, 6, 15))
    end

    with_tenant(OTHER_TENANT) do
      assert_raises(ArgumentError) do
        @service.record_staff_entry!(check, eligibility_group: "other")
      end
    end

    assert_group_fields_under_tenant(check, TENANT, nil, nil)
  end

  # -- Issue #646 ADR 0002: record_staff_entry! must not leak via error text -------

  test "record_staff_entry! from another tenant for other tenant medicare_a check raises ArgumentError and does not write" do
    medicare_check = nil
    with_tenant(TENANT) do
      medicare_check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral(patient_id: "pt_mcd_adr_mca_001"),
        resource_type: "medicare_a",
        status: "checking"
      )
    end

    with_tenant(OTHER_TENANT) do
      assert_raises(ArgumentError) do
        @service.record_staff_entry!(medicare_check, eligibility_group: "other")
      end
    end

    assert_group_fields_under_tenant(medicare_check, TENANT, nil, nil)
  end

  test "record_staff_entry! from another tenant for nonexistent check id raises ArgumentError and does not write" do
    medicaid_check = nil
    max_check_id = nil
    with_tenant(TENANT) do
      medicaid_check = medicaid_check_for(patient_id: "pt_mcd_adr_missing_001", dob: Date.new(1996, 6, 15))
      max_check_id = Corvid::AlternateResourceCheck.maximum(:id)
    end
    missing_row_check = Corvid::AlternateResourceCheck.new(
      id: max_check_id + 1000,
      resource_type: "medicaid"
    )

    with_tenant(OTHER_TENANT) do
      assert_raises(ArgumentError) do
        @service.record_staff_entry!(missing_row_check, eligibility_group: "other")
      end
    end

    assert_group_fields_under_tenant(medicaid_check, TENANT, nil, nil)
  end

  test "record_staff_entry! from another tenant uses identical ArgumentError message for medicaid medicare_a and missing row" do
    medicaid_check = nil
    medicare_check = nil
    max_check_id = nil
    with_tenant(TENANT) do
      medicaid_check = medicaid_check_for(patient_id: "pt_mcd_adr_msg_001", dob: Date.new(1996, 6, 15))
      medicare_check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral(patient_id: "pt_mcd_adr_msg_002"),
        resource_type: "medicare_a",
        status: "checking"
      )
      max_check_id = Corvid::AlternateResourceCheck.maximum(:id)
    end
    missing_row_check = Corvid::AlternateResourceCheck.new(
      id: max_check_id + 1000,
      resource_type: "medicaid"
    )

    medicaid_message = medicare_message = missing_message = nil
    with_tenant(OTHER_TENANT) do
      medicaid_message = staff_entry_argument_error_message do
        @service.record_staff_entry!(medicaid_check, eligibility_group: "other")
      end
      medicare_message = staff_entry_argument_error_message do
        @service.record_staff_entry!(medicare_check, eligibility_group: "other")
      end
    end

    assert_equal medicaid_message, medicare_message

    with_tenant(OTHER_TENANT) do
      missing_message = staff_entry_argument_error_message do
        @service.record_staff_entry!(missing_row_check, eligibility_group: "other")
      end
    end

    assert_equal medicaid_message, missing_message

    assert_group_fields_under_tenant(medicaid_check, TENANT, nil, nil)
    assert_group_fields_under_tenant(medicare_check, TENANT, nil, nil)
  end

  test "record! without tenant context does not write stated group" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_tenant_004", dob: Date.new(1996, 6, 15))
    end

    coverage = {
      state: "XA",
      eligibility_group: "other",
      eligibility_group_source: "registration"
    }
    result = @service.record!(check, coverage: coverage, date_of_service: DOS)

    assert_nil result
    assert_group_fields_under_tenant(check, TENANT, nil, nil)
  end

  test "record! without tenant context does not write inferred group" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_tenant_005", dob: Date.new(1996, 6, 15))
    end

    result = @service.record!(
      check,
      coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
      date_of_service: DOS
    )

    assert_nil result
    assert_group_fields_under_tenant(check, TENANT, nil, nil)
  end

  test "record_staff_entry! without tenant context raises and does not write" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_tenant_006", dob: Date.new(1996, 6, 15))
    end

    assert_raises(ArgumentError) do
      @service.record_staff_entry!(check, eligibility_group: "other")
    end

    assert_group_fields_under_tenant(check, TENANT, nil, nil)
  end

  # -- Issue #646 ADR 0002 chair: lock before visibility, missing row, no tenant -------

  test "record! from another tenant does not issue FOR UPDATE before visibility" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_adr_lock_001", dob: Date.new(1996, 6, 15))
    end

    sql = nil
    with_tenant(OTHER_TENANT) do
      sql = capture_sql do
        @service.record!(
          check,
          coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
          date_of_service: DOS
        )
      end
    end

    assert_no_for_update_sql(sql)
  end

  test "record! for nonexistent check id does not issue FOR UPDATE" do
    max_check_id = nil
    with_tenant(TENANT) do
      medicaid_check_for(patient_id: "pt_mcd_adr_lock_missing_anchor", dob: Date.new(1996, 6, 15))
      max_check_id = Corvid::AlternateResourceCheck.maximum(:id)
    end
    missing_row_check = Corvid::AlternateResourceCheck.new(
      id: max_check_id + 1000,
      resource_type: "medicaid"
    )

    sql = nil
    with_tenant(TENANT) do
      sql = capture_sql do
        invoke_record_ignoring_missing_row do
          @service.record!(
            missing_row_check,
            coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
            date_of_service: DOS
          )
        end
      end
    end

    assert_no_for_update_sql(sql)
  end

  test "record_staff_entry! from another tenant does not issue FOR UPDATE before visibility" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_adr_lock_002", dob: Date.new(1996, 6, 15))
    end

    sql = nil
    with_tenant(OTHER_TENANT) do
      sql = capture_sql do
        assert_raises(ArgumentError) do
          @service.record_staff_entry!(check, eligibility_group: "other")
        end
      end
    end

    assert_no_for_update_sql(sql)
  end

  test "record_staff_entry! for nonexistent check id does not issue FOR UPDATE" do
    max_check_id = nil
    with_tenant(TENANT) do
      medicaid_check_for(patient_id: "pt_mcd_adr_lock_missing_staff", dob: Date.new(1996, 6, 15))
      max_check_id = Corvid::AlternateResourceCheck.maximum(:id)
    end
    missing_row_check = Corvid::AlternateResourceCheck.new(
      id: max_check_id + 1000,
      resource_type: "medicaid"
    )

    sql = nil
    with_tenant(TENANT) do
      sql = capture_sql do
        assert_raises(ArgumentError) do
          @service.record_staff_entry!(missing_row_check, eligibility_group: "other")
        end
      end
    end

    assert_no_for_update_sql(sql)
  end

  test "record! from another tenant does not call adapter for inference" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_adr_adapter_001", dob: Date.new(1996, 6, 15))
    end

    counting = CountingAdapterDelegate.new(@adapter)
    service = Corvid::MedicaidEligibilityGroupService.new(adapter: counting)

    with_tenant(OTHER_TENANT) do
      service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )
    end

    assert_equal 0, counting.find_patient_calls
  end

  test "record! for nonexistent check id does not call adapter for inference" do
    max_check_id = nil
    with_tenant(TENANT) do
      medicaid_check_for(patient_id: "pt_mcd_adr_adapter_missing", dob: Date.new(1996, 6, 15))
      max_check_id = Corvid::AlternateResourceCheck.maximum(:id)
    end
    missing_row_check = Corvid::AlternateResourceCheck.new(
      id: max_check_id + 1000,
      resource_type: "medicaid"
    )

    counting = CountingAdapterDelegate.new(@adapter)
    service = Corvid::MedicaidEligibilityGroupService.new(adapter: counting)

    with_tenant(TENANT) do
      invoke_record_ignoring_missing_row do
        service.record!(
          missing_row_check,
          coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
          date_of_service: DOS
        )
      end
    end

    assert_equal 0, counting.find_patient_calls
  end

  test "record! for nonexistent check id returns nil without RecordNotFound" do
    max_check_id = nil
    with_tenant(TENANT) do
      medicaid_check_for(patient_id: "pt_mcd_adr_nil_missing", dob: Date.new(1996, 6, 15))
      max_check_id = Corvid::AlternateResourceCheck.maximum(:id)
    end
    missing_row_check = Corvid::AlternateResourceCheck.new(
      id: max_check_id + 1000,
      resource_type: "medicaid"
    )

    result = raised = nil
    with_tenant(TENANT) do
      begin
        result = @service.record!(
          missing_row_check,
          coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
          date_of_service: DOS
        )
      rescue ActiveRecord::RecordNotFound => e
        raised = e
      end
    end

    assert_nil raised, "record! must not raise RecordNotFound for a missing row"
    assert_nil result
  end

  test "record_staff_entry! for nonexistent check id raises not-visible ArgumentError without RecordNotFound cause" do
    max_check_id = nil
    with_tenant(TENANT) do
      medicaid_check_for(patient_id: "pt_mcd_adr_cause_missing", dob: Date.new(1996, 6, 15))
      max_check_id = Corvid::AlternateResourceCheck.maximum(:id)
    end
    missing_row_check = Corvid::AlternateResourceCheck.new(
      id: max_check_id + 1000,
      resource_type: "medicaid"
    )

    error = nil
    with_tenant(TENANT) do
      error = assert_raises(ArgumentError) do
        @service.record_staff_entry!(missing_row_check, eligibility_group: "other")
      end
    end

    assert_equal "eligibility group cannot be recorded", error.message
    refute_record_not_found_in_cause_chain(error)
  end

  test "record_staff_entry! from another tenant raises not-visible ArgumentError without RecordNotFound cause" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_adr_cause_hidden", dob: Date.new(1996, 6, 15))
    end

    error = nil
    with_tenant(OTHER_TENANT) do
      error = assert_raises(ArgumentError) do
        @service.record_staff_entry!(check, eligibility_group: "other")
      end
    end

    assert_equal "eligibility group cannot be recorded", error.message
    refute_record_not_found_in_cause_chain(error)
  end

  test "record! without tenant context does not issue FOR UPDATE" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_adr_lock_no_ctx", dob: Date.new(1996, 6, 15))
    end

    sql = capture_sql do
      @service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )
    end

    assert_no_for_update_sql(sql)
  end

  test "record_staff_entry! without tenant context does not issue FOR UPDATE" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_adr_lock_no_ctx_staff", dob: Date.new(1996, 6, 15))
    end

    sql = capture_sql do
      assert_raises(ArgumentError) do
        @service.record_staff_entry!(check, eligibility_group: "other")
      end
    end

    assert_no_for_update_sql(sql)
  end

  test "record_staff_entry! without tenant context raises not-visible ArgumentError with expected message" do
    check = nil
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_adr_msg_no_ctx", dob: Date.new(1996, 6, 15))
    end

    error = assert_raises(ArgumentError) do
      @service.record_staff_entry!(check, eligibility_group: "other")
    end

    assert_equal "eligibility group cannot be recorded", error.message
  end

  # -- Issue #646 round 2: locked row, adapter outside lock, coverage edge cases -------

  test "record! uses locked row referral not caller prc_referral_id swap and writes nothing" do
    other_referral = nil
    with_tenant(OTHER_TENANT) do
      other_referral = create_referral(patient_id: "pt_mcd_lock_ref_001")
    end

    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_lock_001", dob: Date.new(1996, 6, 15))
      decoy_referral = create_referral(patient_id: "pt_mcd_lock_decoy_001")
      check.update_column(:prc_referral_id, other_referral.id)

      caller = Corvid::AlternateResourceCheck.find(check.id)
      caller.prc_referral_id = decoy_referral.id

      result = @service.record!(
        caller,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_nil result
      reloaded = Corvid::AlternateResourceCheck.find(check.id)
      assert_nil reloaded.eligibility_group
      assert_nil reloaded.eligibility_group_source
      assert_nil reloaded.eligibility_group_set_at
    end
  end

  test "record_staff_entry! uses locked row referral not caller prc_referral_id swap" do
    other_referral = nil
    with_tenant(OTHER_TENANT) do
      other_referral = create_referral(patient_id: "pt_mcd_lock_ref_002")
    end

    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_lock_002", dob: Date.new(1996, 6, 15))
      decoy_referral = create_referral(patient_id: "pt_mcd_lock_decoy_002")
      check.update_column(:prc_referral_id, other_referral.id)

      caller = Corvid::AlternateResourceCheck.find(check.id)
      caller.prc_referral_id = decoy_referral.id

      assert_raises(ArgumentError) do
        @service.record_staff_entry!(caller, eligibility_group: "other")
      end

      reloaded = Corvid::AlternateResourceCheck.find(check.id)
      assert_nil reloaded.eligibility_group
      assert_nil reloaded.eligibility_group_source
      assert_nil reloaded.eligibility_group_set_at
    end
  end

  test "record! uses locked row resource_type not caller medicare_a copy and infers" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_lock_003", dob: Date.new(1996, 6, 15))
      caller = Corvid::AlternateResourceCheck.find(check.id)
      caller.resource_type = "medicare_a"

      result = @service.record!(
        caller,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! calls adapter find_patient outside the row lock" do
    with_tenant(TENANT) do
      observing = LockObservingAdapterDelegate.new(@adapter)
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: observing)
      check = medicaid_check_for(patient_id: "pt_mcd_lock_004", dob: Date.new(1996, 6, 15))

      observing.baseline = ActiveRecord::Base.connection.open_transactions
      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "expansion_adult", result
      assert observing.find_patient_outside_lock?, "find_patient must run outside the row lock"
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! ignores wrong-case stated eligibility_group and infers" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stmt_001", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "WAIVER_ADULT",
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! ignores bogus string stated eligibility_group and infers" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stmt_bogus", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "bogus",
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! ignores empty-symbol stated eligibility_group and infers" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stmt_empty_sym", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: :"",
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! ignores false stated eligibility_group and infers" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stmt_false", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: false,
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! ignores integer stated eligibility_group and infers" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stmt_42", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: 42,
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! does not overwrite state_case_data group when stated value is unrecognised" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stmt_preserve", dob: Date.new(1996, 6, 15))
      stated = {
        state: "XA",
        eligibility_group: "waiver_adult",
        eligibility_group_source: "state_case_data"
      }
      @service.record!(check, coverage: stated, date_of_service: DOS)

      coverage = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "WAIVER_ADULT",
        eligibility_group_source: "registration"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "waiver_adult", result
      assert_group_fields(check, "waiver_adult", "state_case_data")
    end
  end

  test "record! infers after unrecognised stated value when prior state_case_data group cleared" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_stmt_later", dob: Date.new(1996, 6, 15))
      bogus = {
        state: "XA",
        plan_name: "TEST REGULAR PLAN",
        eligibility_group: "bogus",
        eligibility_group_source: "registration"
      }
      @service.record!(check, coverage: bogus, date_of_service: DOS)
      assert_group_fields(check, "expansion_adult", "inferred")

      clean = { state: "XA", plan_name: "TEST REGULAR PLAN" }
      result = @service.record!(check, coverage: clean, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! uses Denver business date for Time date_of_service before 65th birthday" do
    original_zone = Time.zone
    Time.zone = "America/Denver"
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_tz_001", dob: Date.new(1961, 6, 15))
      dos = Time.utc(2026, 6, 15, 2, 0)
      result = @service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: dos
      )

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  ensure
    Time.zone = original_zone
  end

  test "record! matches Denver TimeWithZone date_of_service to UTC instant for age" do
    original_zone = Time.zone
    Time.zone = "America/Denver"
    with_tenant(TENANT) do
      check_utc = medicaid_check_for(patient_id: "pt_mcd_tz_002a", dob: Date.new(1961, 6, 15))
      check_local = medicaid_check_for(patient_id: "pt_mcd_tz_002b", dob: Date.new(1961, 6, 15))
      instant = Time.utc(2026, 6, 15, 2, 0)
      local_dos = instant.in_time_zone("America/Denver")

      utc_result = @service.record!(
        check_utc,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: instant
      )
      local_result = @service.record!(
        check_local,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: local_dos
      )

      assert_equal "expansion_adult", utc_result
      assert_equal "expansion_adult", local_result
      assert_group_fields(check_utc, "expansion_adult", "inferred")
      assert_group_fields(check_local, "expansion_adult", "inferred")
    end
  ensure
    Time.zone = original_zone
  end

  test "record! reads string-keyed eligibility_group when symbol key is nil" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_mixed_001", dob: Date.new(1996, 6, 15))
      coverage = {
        eligibility_group: nil,
        "eligibility_group" => "waiver_adult",
        state: "XB",
        plan_name: "TEST SYNTHETIC WAIVER PLAN"
      }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "waiver_adult", result
      assert_group_fields(check, "waiver_adult", "eligibility_response")
    end
  end

  test "record! infers expansion_adult for XA age 30 without plan_name" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_xa_noplan_001", dob: Date.new(1996, 6, 15))
      result = @service.record!(check, coverage: { state: "XA" }, date_of_service: DOS)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! infers expansion_adult for XA age 30 with whitespace-only plan_name" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_xa_noplan_002", dob: Date.new(1996, 6, 15))
      result = @service.record!(
        check,
        coverage: { state: "XA", plan_name: "   " },
        date_of_service: DOS
      )

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! infers other for XA age 70 without plan_name" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_xa_noplan_003", dob: Date.new(1956, 6, 15))
      result = @service.record!(check, coverage: { state: "XA" }, date_of_service: DOS)

      assert_equal "other", result
      assert_group_fields(check, "other", "inferred")
    end
  end

  # -- Issue #646 round 3: stale inference race, skip adapter, DOB/DOS types ---------

  test "record! records unknown when concurrent inference disagrees during find_patient" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_001", dob: Date.new(1996, 6, 15))
      racing = RaceSimulatingAdapterDelegate.new(
        @adapter,
        on_first_find_patient: lambda {
          check.update!(
            eligibility_group: "unknown",
            eligibility_group_source: "inferred",
            eligibility_group_set_at: Time.current
          )
        }
      )
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: racing)

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  test "record! keeps inferred group when concurrent write matches computed inference" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_002", dob: Date.new(1996, 6, 15))
      racing = RaceSimulatingAdapterDelegate.new(
        @adapter,
        on_first_find_patient: lambda {
          check.update!(
            eligibility_group: "expansion_adult",
            eligibility_group_source: "inferred",
            eligibility_group_set_at: Time.current
          )
        }
      )
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: racing)

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! does not overwrite staff_entry when concurrent write happens during find_patient" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_003", dob: Date.new(1996, 6, 15))
      inner_service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
      racing = RaceSimulatingAdapterDelegate.new(
        @adapter,
        on_first_find_patient: lambda {
          inner_service.record_staff_entry!(check, eligibility_group: "other")
        }
      )
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: racing)

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "other", result
      assert_group_fields(check, "other", "staff_entry")
    end
  end

  test "record! with supersede_stated infers over prior stated group when coverage does not state a real group" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_670_sup_001", dob: Date.new(1996, 6, 15))
      stated = {
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      }
      @service.record!(check, coverage: stated, date_of_service: DOS)
      assert_group_fields(check, "expansion_adult", "eligibility_response")

      coverage = { state: "XA", plan_name: "TEST REGULAR PLAN", eligibility_group: nil }
      result = @service.record!(check, coverage: coverage, date_of_service: DOS, supersede_stated: true)

      assert_equal "expansion_adult", result
      assert_group_fields(check, "expansion_adult", "inferred")
    end
  end

  test "record! with supersede_stated does not overwrite newer stated group written during find_patient" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_670_race_001", dob: Date.new(1996, 6, 15))
      stated = {
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      }
      @service.record!(check, coverage: stated, date_of_service: DOS)
      assert_group_fields(check, "expansion_adult", "eligibility_response")

      inner_service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
      racing = RaceSimulatingAdapterDelegate.new(
        @adapter,
        on_first_find_patient: lambda {
          inner_service.record!(
            check,
            coverage: {
              state: "XA",
              eligibility_group: "waiver_adult",
              eligibility_group_source: "state_case_data"
            },
            date_of_service: DOS
          )
        }
      )
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: racing)

      result = service.record!(
        check,
        coverage: {},
        date_of_service: DOS,
        supersede_stated: true
      )

      assert_equal "waiver_adult", result
      assert_group_fields(check, "waiver_adult", "state_case_data")
    end
  end

  test "record! with supersede_stated does not overwrite newer stated group written during StateMedicaidRules.lookup" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_670_race_002", dob: Date.new(1996, 6, 15))
      stated = {
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response"
      }
      @service.record!(check, coverage: stated, date_of_service: DOS)
      assert_group_fields(check, "expansion_adult", "eligibility_response")

      inner_service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
      lookup = Corvid::StateMedicaidRules.method(:lookup)
      first_lookup = true
      concurrent_lookup = lambda do |state|
        if first_lookup
          first_lookup = false
          inner_service.record!(
            check,
            coverage: {
              state: "XA",
              eligibility_group: "waiver_adult",
              eligibility_group_source: "state_case_data"
            },
            date_of_service: DOS
          )
        end
        lookup.call(state)
      end

      result = nil
      Corvid::StateMedicaidRules.stub(:lookup, concurrent_lookup) do
        result = @service.record!(
          check,
          coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
          date_of_service: DOS,
          supersede_stated: true
        )
      end

      assert_equal "waiver_adult", result
      assert_group_fields(check, "waiver_adult", "state_case_data")
    end
  end

  test "record! records unknown when nested record! disagrees during find_patient" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_004", dob: Date.new(1996, 6, 15))
      inner_service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
      racing = RaceSimulatingAdapterDelegate.new(
        @adapter,
        on_first_find_patient: lambda {
          inner_service.record!(
            check,
            coverage: { state: "ZZ", plan_name: "TEST REGULAR PLAN" },
            date_of_service: DOS
          )
        }
      )
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: racing)

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "unknown", result
      assert_group_fields(check, "unknown", "inferred")
    end
  end

  # -- Issue #646 round 2 chair: row deleted and referral moved during adapter lookup -

  test "record! returns nil without RecordNotFound when row deleted during find_patient" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_del_001", dob: Date.new(1996, 6, 15))
      check_id = check.id
      racing = RaceSimulatingAdapterDelegate.new(
        @adapter,
        on_first_find_patient: lambda {
          Corvid::AlternateResourceCheck.where(id: check_id).delete_all
        }
      )
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: racing)

      result = raised = nil
      begin
        result = service.record!(
          check,
          coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
          date_of_service: DOS
        )
      rescue ActiveRecord::RecordNotFound => e
        raised = e
      end

      assert_nil raised, "record! must not raise RecordNotFound when row disappears before lock"
      assert_nil result
      assert_equal 0, Corvid::AlternateResourceCheck.where(id: check_id).count
    end
  end

  test "record! writes nothing when referral changes to different inference group during find_patient" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_ref_diff_001", dob: Date.new(1996, 6, 15))
      other_patient_id = "pt_mcd_race_ref_diff_002"
      @adapter.add_patient(
        other_patient_id,
        display_name: "TEST,PATIENT 002",
        dob: Date.new(1956, 6, 15),
        sex: "F",
        ssn_last4: "0000"
      )
      other_referral = create_referral(patient_id: other_patient_id)
      racing = RaceSimulatingAdapterDelegate.new(
        @adapter,
        on_first_find_patient: lambda {
          check.update_column(:prc_referral_id, other_referral.id)
        }
      )
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: racing)

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_nil result
      reloaded = Corvid::AlternateResourceCheck.find(check.id)
      assert_nil reloaded.eligibility_group
      assert_nil reloaded.eligibility_group_source
      assert_nil reloaded.eligibility_group_set_at
      assert_equal other_referral.id, reloaded.prc_referral_id
    end
  end

  test "record! writes nothing when referral changes to same inference group during find_patient" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_ref_same_001", dob: Date.new(1996, 6, 15))
      other_patient_id = "pt_mcd_race_ref_same_002"
      @adapter.add_patient(
        other_patient_id,
        display_name: "TEST,PATIENT 002",
        dob: Date.new(1996, 6, 15),
        sex: "F",
        ssn_last4: "0000"
      )
      other_referral = create_referral(patient_id: other_patient_id)
      racing = RaceSimulatingAdapterDelegate.new(
        @adapter,
        on_first_find_patient: lambda {
          check.update_column(:prc_referral_id, other_referral.id)
        }
      )
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: racing)

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_nil result
      reloaded = Corvid::AlternateResourceCheck.find(check.id)
      assert_nil reloaded.eligibility_group
      assert_nil reloaded.eligibility_group_source
      assert_nil reloaded.eligibility_group_set_at
      assert_equal other_referral.id, reloaded.prc_referral_id
    end
  end

  # -- PR #657 review: stated coverage after a referral move before the lock ---------

  test "record! writes no stated group when the check moves to another visible referral before the lock" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_ref_stated_001", dob: Date.new(1996, 6, 15))
      other_referral = create_referral(patient_id: "pt_mcd_race_ref_stated_002")
      service = service_moving_check_after_load(check, other_referral)

      result = service.record!(
        check,
        coverage: { state: "XA", eligibility_group: "waiver_adult", eligibility_group_source: "registration" },
        date_of_service: DOS
      )

      assert_nil result
      reloaded = Corvid::AlternateResourceCheck.find(check.id)
      assert_nil reloaded.eligibility_group
      assert_nil reloaded.eligibility_group_source
      assert_nil reloaded.eligibility_group_set_at
      assert_equal other_referral.id, reloaded.prc_referral_id
    end
  end

  test "record! keeps the new referral's stored group when the check moves before a stated write" do
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_race_ref_stated_003", dob: Date.new(1996, 6, 15))
      check.update_columns(
        eligibility_group: "other",
        eligibility_group_source: "inferred",
        eligibility_group_set_at: Time.current
      )
      other_referral = create_referral(patient_id: "pt_mcd_race_ref_stated_004")
      service = service_moving_check_after_load(check, other_referral)

      result = service.record!(
        check,
        coverage: { state: "XA", eligibility_group: "expansion_adult" },
        date_of_service: DOS
      )

      assert_equal "other", result
      assert_group_fields(check, "other", "inferred")
    end
  end

  test "record! does not call find_patient when coverage states a recognised group" do
    with_tenant(TENANT) do
      counting = CountingAdapterDelegate.new(@adapter)
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: counting)
      check = medicaid_check_for(patient_id: "pt_mcd_skip_001", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        eligibility_group: "waiver_adult",
        eligibility_group_source: "registration"
      }

      result = service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "waiver_adult", result
      assert_equal 0, counting.find_patient_calls
      assert_group_fields(check, "waiver_adult", "registration")
    end
  end

  test "record! does not call find_patient when row already has staff_entry" do
    with_tenant(TENANT) do
      counting = CountingAdapterDelegate.new(@adapter)
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: counting)
      check = medicaid_check_for(patient_id: "pt_mcd_skip_002", dob: Date.new(1996, 6, 15))
      service.record_staff_entry!(check, eligibility_group: "other")

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "other", result
      assert_equal 0, counting.find_patient_calls
      assert_group_fields(check, "other", "staff_entry")
    end
  end

  test "record! does not call find_patient when row already has stated non-inferred group" do
    with_tenant(TENANT) do
      counting = CountingAdapterDelegate.new(@adapter)
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: counting)
      check = medicaid_check_for(patient_id: "pt_mcd_skip_003", dob: Date.new(1996, 6, 15))
      stated = {
        state: "XA",
        eligibility_group: "waiver_adult",
        eligibility_group_source: "state_case_data"
      }
      service.record!(check, coverage: stated, date_of_service: DOS)
      counting.reset_find_patient_calls!

      result = service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: DOS
      )

      assert_equal "waiver_adult", result
      assert_equal 0, counting.find_patient_calls
      assert_group_fields(check, "waiver_adult", "state_case_data")
    end
  end

  test "record! persists stated group when find_patient would raise Timeout::Error" do
    with_tenant(TENANT) do
      counting = CountingAdapterDelegate.new(@adapter, find_patient_raises: Timeout::Error)
      service = Corvid::MedicaidEligibilityGroupService.new(adapter: counting)
      check = medicaid_check_for(patient_id: "pt_mcd_skip_004", dob: Date.new(1996, 6, 15))
      coverage = {
        state: "XA",
        eligibility_group: "other",
        eligibility_group_source: "eligibility_response"
      }

      result = service.record!(check, coverage: coverage, date_of_service: DOS)

      assert_equal "other", result
      assert_group_fields(check, "other", "eligibility_response")
    end
  end

  test "record! treats Time date of birth as calendar date without zone shift in Denver" do
    original_zone = Time.zone
    Time.zone = "America/Denver"
    with_tenant(TENANT) do
      patient_id = "pt_mcd_dob_time_001"
      @adapter.add_patient(
        patient_id,
        display_name: "TEST,PATIENT 001",
        dob: Time.utc(2007, 6, 15),
        sex: "F",
        ssn_last4: "0000"
      )
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: create_referral(patient_id: patient_id),
        resource_type: "medicaid",
        status: "checking"
      )
      result = @service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: Date.new(2026, 6, 14)
      )

      assert_equal "other", result
      assert_group_fields(check, "other", "inferred")
    end
  ensure
    Time.zone = original_zone
  end

  test "record! converts DateTime date_of_service like Time for age in UTC" do
    original_zone = Time.zone
    Time.zone = "UTC"
    with_tenant(TENANT) do
      check = medicaid_check_for(patient_id: "pt_mcd_dos_dt_001", dob: Date.new(2007, 6, 15))
      dos_datetime = DateTime.new(2026, 6, 14, 20, 0, 0, "-07:00")
      dos_time = Time.utc(2026, 6, 15, 3, 0, 0)

      datetime_result = @service.record!(
        check,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: dos_datetime
      )
      check_time = medicaid_check_for(patient_id: "pt_mcd_dos_dt_002", dob: Date.new(2007, 6, 15))
      time_result = @service.record!(
        check_time,
        coverage: { state: "XA", plan_name: "TEST REGULAR PLAN" },
        date_of_service: dos_time
      )

      assert_equal "expansion_adult", datetime_result
      assert_equal "expansion_adult", time_result
      assert_group_fields(check, "expansion_adult", "inferred")
      assert_group_fields(check_time, "expansion_adult", "inferred")
    end
  ensure
    Time.zone = original_zone
  end

  # -- ADR 0003: date of birth never persisted or logged ------------------------------

  test "record! does not write or log synthetic date of birth" do
    with_tenant(TENANT) do
      dob = Date.new(1990, 3, 17)
      iso_dob = dob.iso8601
      check = medicaid_check_for(patient_id: "pt_mcd_privacy", dob: dob)

      rails_log = StringIO.new
      sql_log = StringIO.new
      original_rails_logger = Rails.logger
      original_ar_logger = ActiveRecord::Base.logger
      Rails.logger = ActiveSupport::Logger.new(rails_log)
      ActiveRecord::Base.logger = ActiveSupport::Logger.new(sql_log)

      record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      combined = rails_log.string + sql_log.string
      refute_includes combined, iso_dob
      refute_includes combined, "1990-03-17"
      refute_includes combined, "03-17"
      refute_includes combined, "1990"

      check.reload
      row_text = check.attributes.values.compact.map(&:to_s).join(" ")
      refute_includes row_text, iso_dob
      refute_includes row_text, "1990-03-17"

      error_message = nil
      begin
        @service.record_staff_entry!(check, eligibility_group: "not_valid")
      rescue ArgumentError => e
        error_message = e.message
      end
      refute_nil error_message
      refute_includes error_message, iso_dob
      refute_includes error_message, "1990"
    ensure
      Rails.logger = original_rails_logger
      ActiveRecord::Base.logger = original_ar_logger
    end
  end

  class RaceSimulatingAdapterDelegate
    def initialize(inner, on_first_find_patient:)
      @inner = inner
      @on_first_find_patient = on_first_find_patient
      @first_call = true
    end

    def find_patient(patient_id)
      if @first_call
        @first_call = false
        @on_first_find_patient.call
      end
      @inner.find_patient(patient_id)
    end

    def respond_to_missing?(method, include_private = false)
      @inner.respond_to?(method, include_private) || super
    end

    def method_missing(method, *args, **kwargs, &block)
      @inner.public_send(method, *args, **kwargs, &block)
    end
  end

  class CountingAdapterDelegate
    attr_reader :find_patient_calls

    def initialize(inner, find_patient_raises: nil)
      @inner = inner
      @find_patient_raises = find_patient_raises
      @find_patient_calls = 0
    end

    def reset_find_patient_calls!
      @find_patient_calls = 0
    end

    def find_patient(patient_id)
      @find_patient_calls += 1
      raise @find_patient_raises if @find_patient_raises

      @inner.find_patient(patient_id)
    end

    def respond_to_missing?(method, include_private = false)
      @inner.respond_to?(method, include_private) || super
    end

    def method_missing(method, *args, **kwargs, &block)
      @inner.public_send(method, *args, **kwargs, &block)
    end
  end

  # Delegates to the test adapter and records whether find_patient ran without
  # an extra transaction opened by the service (e.g. row with_lock).
  class LockObservingAdapterDelegate
    attr_accessor :baseline
    attr_reader :find_patient_outside_lock

    def initialize(inner)
      @inner = inner
      @baseline = nil
      @find_patient_outside_lock = false
    end

    def find_patient_outside_lock?
      @find_patient_outside_lock
    end

    def find_patient(patient_id)
      @find_patient_outside_lock =
        ActiveRecord::Base.connection.open_transactions == @baseline
      @inner.find_patient(patient_id)
    end

    def respond_to_missing?(method, include_private = false)
      @inner.respond_to?(method, include_private) || super
    end

    def method_missing(method, *args, **kwargs, &block)
      @inner.public_send(method, *args, **kwargs, &block)
    end
  end

  private

  def stale_in_memory_check_after(check)
    snapshot = Corvid::AlternateResourceCheck.find(check.id).attributes.slice(
      "eligibility_group",
      "eligibility_group_source",
      "eligibility_group_set_at"
    )
    yield
    stale = Corvid::AlternateResourceCheck.find(check.id)
    stale.assign_attributes(snapshot)
    stale
  end

  def medicaid_check_for(patient_id:, dob: Date.new(1996, 6, 15), register_patient: true, facility_identifier: "fac_test")
    if register_patient
      @adapter.add_patient(
        patient_id,
        display_name: "TEST,PATIENT 001",
        dob: dob,
        sex: "F",
        ssn_last4: "0000"
      )
    end
    Corvid::AlternateResourceCheck.create!(
      prc_referral: create_referral(patient_id: patient_id, facility_identifier: facility_identifier),
      resource_type: "medicaid",
      status: "checking"
    )
  end

  # Moves the check to another referral right after the service's
  # unlocked load and before its row lock. A stated group makes no
  # adapter call, so the move cannot ride on find_patient.
  def service_moving_check_after_load(check, other_referral)
    service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
    service.define_singleton_method(:persisted_check) do |target|
      super(target).tap { check.update_column(:prc_referral_id, other_referral.id) }
    end
    service
  end

  def create_referral(patient_id:, facility_identifier: "fac_test")
    kase = Corvid::Case.create!(
      patient_identifier: patient_id,
      lifecycle_status: "intake",
      facility_identifier: facility_identifier
    )
    Corvid::PrcReferral.create!(case: kase, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def record!(check, state: nil, plan_name: nil, date_of_service: DOS, patient_dob: nil)
    if patient_dob
      patient_id = check.prc_referral.case.patient_identifier
      @adapter.add_patient(
        patient_id,
        display_name: "TEST,PATIENT 001",
        dob: patient_dob,
        sex: "F",
        ssn_last4: "0000"
      )
    end

    coverage = {}
    coverage[:state] = state unless state.nil?
    coverage[:plan_name] = plan_name unless plan_name.nil?
    @service.record!(check, coverage: coverage, date_of_service: date_of_service)
  end

  def assert_group_fields(check, group, source)
    check.reload
    assert_equal group, check.eligibility_group
    assert_equal source, check.eligibility_group_source
    refute_nil check.eligibility_group_set_at unless group.nil?
  end

  # Minitest 6 rejects assert_equal(nil, ...); expected nil must be stated explicitly.
  def assert_equal_or_nil(expected, actual)
    expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
  end

  def assert_group_fields_under_tenant(check, tenant, group, source)
    with_tenant(tenant) do
      reloaded = Corvid::AlternateResourceCheck.find(check.id)
      assert_equal_or_nil group, reloaded.eligibility_group
      assert_equal_or_nil source, reloaded.eligibility_group_source
      if group.nil?
        assert_nil reloaded.eligibility_group_set_at
      else
        refute_nil reloaded.eligibility_group_set_at
      end
    end
  end

  def staff_entry_argument_error_message
    error = assert_raises(ArgumentError) { yield }
    error.message
  end

  def capture_sql
    statements = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      statements << sql if sql
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    statements
  end

  def assert_no_for_update_sql(statements)
    for_update = statements.grep(/FOR\s+UPDATE/i)
    assert_empty for_update, "expected no row lock SQL, got: #{for_update.join('; ')}"
  end

  def refute_record_not_found_in_cause_chain(error)
    cause = error
    while cause
      refute_kind_of ActiveRecord::RecordNotFound, cause
      cause = cause.cause
    end
  end

  def invoke_record_ignoring_missing_row
    yield
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
