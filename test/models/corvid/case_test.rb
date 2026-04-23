# frozen_string_literal: true

require "test_helper"

class Corvid::CaseTest < ActiveSupport::TestCase
  TEST_TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"

  setup do
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # TABLE & TENANT
  # =============================================================================

  test "table is corvid_cases" do
    assert_equal "corvid_cases", Corvid::Case.table_name
  end

  test "queries without tenant context raise" do
    assert_raises(Corvid::MissingTenantContextError) do
      Corvid::Case.first
    end
  end

  test "tenant_identifier validation is registered" do
    validators = Corvid::Case.validators_on(:tenant_identifier)
    assert validators.any? { |v| v.is_a?(ActiveRecord::Validations::PresenceValidator) }
  end

  test "auto-assigns tenant_identifier from context" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test_001")
      assert_equal TEST_TENANT, kase.tenant_identifier
    end
  end

  test "queries scoped to current tenant" do
    with_tenant(TEST_TENANT) do
      Corvid::Case.create!(patient_identifier: "pt_a")
    end
    with_tenant(OTHER_TENANT) do
      Corvid::Case.create!(patient_identifier: "pt_b")
    end

    with_tenant(TEST_TENANT) do
      patients = Corvid::Case.pluck(:patient_identifier)
      assert_includes patients, "pt_a"
      refute_includes patients, "pt_b"
    end
  end

  # =============================================================================
  # VALIDATIONS
  # =============================================================================

  test "requires patient_identifier" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.new(patient_identifier: nil)
      refute kase.valid?
      assert kase.errors[:patient_identifier].any?
    end
  end

  test "valid with patient_identifier" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.new(patient_identifier: "pt_test")
      assert kase.valid?
    end
  end

  test "program_type must be valid when present" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.new(patient_identifier: "pt_test", program_type: "bogus")
      refute kase.valid?
    end
  end

  test "accepts all valid program types" do
    with_tenant(TEST_TENANT) do
      Corvid::Case::PROGRAM_TYPES.each do |type|
        kase = Corvid::Case.new(patient_identifier: "pt_test", program_type: type)
        assert kase.valid?, "Should accept program_type: #{type}"
      end
    end
  end

  test "allows nil program_type" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.new(patient_identifier: "pt_test", program_type: nil)
      assert kase.valid?
    end
  end

  test "lifecycle_status must be valid" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.new(patient_identifier: "pt_test", lifecycle_status: "bogus")
      refute kase.valid?
    end
  end

  # =============================================================================
  # STATUS ENUM
  # =============================================================================

  test "defaults to active status" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      assert kase.active?
    end
  end

  test "can transition to inactive" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      kase.inactive!
      assert kase.inactive?
    end
  end

  test "can transition to closed" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      kase.closed!
      assert kase.closed?
    end
  end

  # =============================================================================
  # LIFECYCLE STATUS
  # =============================================================================

  test "defaults lifecycle_status to intake" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      assert_equal "intake", kase.lifecycle_status
    end
  end

  test "LIFECYCLE_STATUSES includes all four statuses" do
    expected = %w[intake active_followup closure closed]
    assert_equal expected.sort, Corvid::Case::LIFECYCLE_STATUSES.sort
  end

  test "PROGRAM_TYPES includes all seven programs" do
    expected = %w[immunization sti tb neonatal lead hep_b communicable_disease]
    assert_equal expected.sort, Corvid::Case::PROGRAM_TYPES.sort
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "for_facility scope filters within tenant" do
    with_tenant(TEST_TENANT) do
      Corvid::Case.create!(patient_identifier: "pt_a", facility_identifier: "fac_1")
      Corvid::Case.create!(patient_identifier: "pt_b", facility_identifier: "fac_2")

      facility_1 = Corvid::Case.for_facility("fac_1").pluck(:patient_identifier)
      assert_equal ["pt_a"], facility_1
    end
  end

  test "all_facilities_in_tenant returns all" do
    with_tenant(TEST_TENANT) do
      Corvid::Case.create!(patient_identifier: "pt_a", facility_identifier: "fac_1")
      Corvid::Case.create!(patient_identifier: "pt_b", facility_identifier: "fac_2")

      assert_equal 2, Corvid::Case.all_facilities_in_tenant.count
    end
  end

  test "for_program scope" do
    with_tenant(TEST_TENANT) do
      imm = Corvid::Case.create!(patient_identifier: "pt_a", program_type: "immunization")
      tb = Corvid::Case.create!(patient_identifier: "pt_b", program_type: "tb")

      assert_includes Corvid::Case.for_program("immunization"), imm
      refute_includes Corvid::Case.for_program("immunization"), tb
    end
  end

  test "in_lifecycle scope" do
    with_tenant(TEST_TENANT) do
      intake = Corvid::Case.create!(patient_identifier: "pt_a", lifecycle_status: "intake")
      active = Corvid::Case.create!(patient_identifier: "pt_b", lifecycle_status: "active_followup")

      assert_includes Corvid::Case.in_lifecycle("intake"), intake
      refute_includes Corvid::Case.in_lifecycle("intake"), active
    end
  end

  # =============================================================================
  # PATIENT DISPLAY
  # =============================================================================

  test "patient returns PatientReference from adapter" do
    Corvid.adapter.add_patient("pt_test_002", display_name: "TEST,PATIENT 002", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "0002")
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test_002")
      assert_instance_of Corvid::PatientReference, kase.patient
      assert_equal "TEST,PATIENT 002", kase.patient.display_name
    end
  end

  test "patient returns nil for unknown identifier" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_nonexistent")
      assert_nil kase.patient
    end
  end

  test "display_name uses cached name" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(
        patient_identifier: "pt_cached",
        patient_name_cached: "CACHED,NAME"
      )
      assert_equal "CACHED,NAME", kase.display_name
    end
  end

  test "display_name falls back to adapter when no cache" do
    Corvid.adapter.add_patient("pt_test_003", display_name: "TEST,PATIENT 003", dob: nil, sex: nil, ssn_last4: nil)
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test_003")
      assert_equal "TEST,PATIENT 003", kase.display_name
    end
  end

  test "display_name returns Unknown Patient when no patient and no cache" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_nonexistent")
      assert_equal "Unknown Patient", kase.display_name
    end
  end

  # =============================================================================
  # CACHE
  # =============================================================================

  test "cache_patient_data! stores name and dob" do
    Corvid.adapter.add_patient("pt_cache_test", display_name: "CACHE,TEST", dob: Date.new(1990, 6, 15), sex: "M", ssn_last4: "9999")
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_cache_test")
      kase.cache_patient_data!
      kase.reload
      assert_equal "CACHE,TEST", kase.patient_name_cached
      assert_equal Date.new(1990, 6, 15), kase.patient_dob_cached
    end
  end

  # =============================================================================
  # PROGRAM CASE
  # =============================================================================

  test "program_case? returns true when program_type present" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test", program_type: "immunization")
      assert kase.program_case?
    end
  end

  test "program_case? returns false when program_type nil" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      refute kase.program_case?
    end
  end

  # =============================================================================
  # ASSOCIATIONS
  # =============================================================================

  test "has_many prc_referrals" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      referral = Corvid::PrcReferral.create!(case: kase, referral_identifier: "ref_1")
      assert_includes kase.prc_referrals, referral
    end
  end

  test "has_many tasks" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      task = Corvid::Task.create!(taskable: kase, description: "Follow up")
      assert_includes kase.tasks, task
    end
  end

  # =============================================================================
  # PHI AT REST
  # =============================================================================

  test "no notes column at rest (notes_token instead)" do
    columns = Corvid::Case.column_names
    refute_includes columns, "notes"
    assert_includes columns, "notes_token"
  end
end
