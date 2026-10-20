# frozen_string_literal: true

require "test_helper"

class Corvid::MedicaidEligibilityGroupServiceTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"
  DOS = Date.new(2026, 6, 15)

  setup do
    @adapter = Corvid.adapter
    @service = Corvid::MedicaidEligibilityGroupService.new(adapter: @adapter)
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

      result = record!(check, state: "XA", plan_name: "TEST REGULAR PLAN")

      assert_nil result
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

  # -- Issue #646 P3: nil or blank eligibility_group is not a statement ----------------

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

  def medicaid_check_for(patient_id:, dob: Date.new(1996, 6, 15), register_patient: true)
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

  def assert_group_fields_under_tenant(check, tenant, group, source)
    with_tenant(tenant) do
      reloaded = Corvid::AlternateResourceCheck.find(check.id)
      assert_equal group, reloaded.eligibility_group
      assert_equal source, reloaded.eligibility_group_source
      if group.nil?
        assert_nil reloaded.eligibility_group_set_at
      else
        refute_nil reloaded.eligibility_group_set_at
      end
    end
  end
end
