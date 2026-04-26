# frozen_string_literal: true

require "test_helper"

class Corvid::CaseTest < ActiveSupport::TestCase
  TEST_TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"

  # Cucumber runs non-transactionally against the same test DB as rake
  # test, so residue from the last scenario can leak into absolute-count
  # assertions. Clear Corvid::Case up front so each test is hermetic.
  setup do
    Corvid::Case.unscoped.delete_all
  end

  test "table is corvid_cases" do
    assert_equal "corvid_cases", Corvid::Case.table_name
  end

  test "queries without tenant context raise" do
    assert_raises(Corvid::MissingTenantContextError) do
      Corvid::Case.first
    end
  end

  test "tenant_identifier validation is registered" do
    # The TenantScoped concern declares: validates :tenant_identifier, presence: true
    validators = Corvid::Case.validators_on(:tenant_identifier)
    assert validators.any? { |v| v.is_a?(ActiveRecord::Validations::PresenceValidator) },
           "Corvid::Case should validate tenant_identifier presence"
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

  test "for_facility scope filters within tenant" do
    with_tenant(TEST_TENANT) do
      Corvid::Case.create!(patient_identifier: "pt_a", facility_identifier: "fac_1")
      Corvid::Case.create!(patient_identifier: "pt_b", facility_identifier: "fac_2")

      facility_1 = Corvid::Case.for_facility("fac_1").pluck(:patient_identifier)
      assert_equal [ "pt_a" ], facility_1
    end
  end

  test "all_facilities_in_tenant returns all" do
    with_tenant(TEST_TENANT) do
      Corvid::Case.create!(patient_identifier: "pt_a", facility_identifier: "fac_1")
      Corvid::Case.create!(patient_identifier: "pt_b", facility_identifier: "fac_2")

      assert_equal 2, Corvid::Case.all_facilities_in_tenant.count
    end
  end

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

  test "no notes column at rest (notes_token instead)" do
    columns = Corvid::Case.column_names
    refute_includes columns, "notes"
    assert_includes columns, "notes_token"
  end

  # -- Status enum -----------------------------------------------------------

  test "defaults to active status" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_status_test")
      assert kase.active?
    end
  end

  test "can transition to inactive" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_inactive")
      kase.inactive!
      assert kase.inactive?
    end
  end

  test "can transition to closed" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_closed")
      kase.closed!
      assert kase.closed?
    end
  end

  # -- Associations ----------------------------------------------------------

  test "has many prc_referrals" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_assoc_ref")
      assert_respond_to kase, :prc_referrals
    end
  end

  test "has many tasks" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_assoc_task")
      assert_respond_to kase, :tasks
    end
  end

  test "belongs to care_team (optional)" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_no_team")
      assert_nil kase.care_team
    end
  end

  # -- Cached patient data ---------------------------------------------------

  test "can store cached patient name" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_cache", patient_name_cached: "John Smith")
      assert_equal "John Smith", kase.patient_name_cached
    end
  end

  test "can store cached patient dob" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_dob", patient_dob_cached: Date.parse("1980-05-15"))
      assert_equal Date.parse("1980-05-15"), kase.patient_dob_cached
    end
  end

  test "cache_patient_data! stores adapter data" do
    Corvid.adapter.add_patient("pt_cache_test", display_name: "CACHE,TEST", dob: Date.new(1985, 6, 15), sex: "M", ssn_last4: "1234")
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_cache_test")
      kase.cache_patient_data!
      kase.reload
      assert_equal "CACHE,TEST", kase.patient_name_cached
      assert_equal Date.new(1985, 6, 15), kase.patient_dob_cached
    end
  end

  # -- program_case? ---------------------------------------------------------

  test "program_case? returns true when program_type present" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_prog", program_type: "hep_b")
      assert kase.program_case?
    end
  end

  test "program_case? returns false when no program_type" do
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_no_prog")
      refute kase.program_case?
    end
  end

  # -- Unscoped ---------------------------------------------------------------

  test "unscoped returns all cases" do
    with_tenant(TEST_TENANT) do
      Corvid::Case.create!(patient_identifier: "pt_us_a")
    end
    with_tenant(OTHER_TENANT) do
      Corvid::Case.create!(patient_identifier: "pt_us_b")
    end

    all_cases = Corvid::Case.unscoped.all
    patients = all_cases.pluck(:patient_identifier)
    assert_includes patients, "pt_us_a"
    assert_includes patients, "pt_us_b"
  end
end
