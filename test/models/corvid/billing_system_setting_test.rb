# frozen_string_literal: true

require "test_helper"

class Corvid::BillingSystemSettingTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"
  FACILITY = "fac_a"
  OTHER_FACILITY = "fac_b"

  EXPECTED_COLUMNS = %w[
    id tenant_identifier facility_identifier visit_type system_of_record
    effective_on expires_on created_at updated_at
  ].freeze

  setup do
    if Corvid.const_defined?(:BillingSystemSetting, false)
      with_tenant(TENANT) { Corvid::BillingSystemSetting.unscoped.delete_all }
      with_tenant(OTHER_TENANT) { Corvid::BillingSystemSetting.unscoped.delete_all }
    end
  end

  # -- Table shape -----------------------------------------------------------

  test "table is corvid_billing_system_settings" do
    assert_equal "corvid_billing_system_settings", Corvid::BillingSystemSetting.table_name
  end

  test "columns are identifiers and effective dates only with no PHI at rest" do
    assert_equal EXPECTED_COLUMNS.sort, Corvid::BillingSystemSetting.column_names.sort

    columns = Corvid::BillingSystemSetting.columns_hash
    assert columns["tenant_identifier"].null == false
    assert columns["facility_identifier"].null == false
    assert columns["visit_type"].null
    assert columns["system_of_record"].null == false
    assert columns["effective_on"].null == false
    assert columns["expires_on"].null

    %w[patient_identifier patient_name ssn dob notes].each do |phi_column|
      refute_includes Corvid::BillingSystemSetting.column_names, phi_column
    end
  end

  # -- Database constraints --------------------------------------------------

  test "database rejects system_of_record outside corvid and ehr on raw insert" do
    now = Time.current
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        Corvid::BillingSystemSetting.transaction(requires_new: true) do
          Corvid::BillingSystemSetting.insert_all!(
            [ {
              tenant_identifier: TENANT,
              facility_identifier: FACILITY,
              visit_type: nil,
              system_of_record: "payer",
              effective_on: Date.new(2020, 1, 1),
              expires_on: nil,
              created_at: now,
              updated_at: now
            } ]
          )
        end
      end
    end
  end

  test "database rejects expires_on before effective_on on raw insert" do
    now = Time.current
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        Corvid::BillingSystemSetting.transaction(requires_new: true) do
          Corvid::BillingSystemSetting.insert_all!(
            [ {
              tenant_identifier: TENANT,
              facility_identifier: FACILITY,
              visit_type: nil,
              system_of_record: "corvid",
              effective_on: Date.new(2024, 6, 1),
              expires_on: Date.new(2024, 5, 1),
              created_at: now,
              updated_at: now
            } ]
          )
        end
      end
    end
  end

  test "database rejects blank visit_type on raw insert" do
    now = Time.current
    with_tenant(TENANT) do
      assert_raises(ActiveRecord::StatementInvalid) do
        Corvid::BillingSystemSetting.transaction(requires_new: true) do
          Corvid::BillingSystemSetting.insert_all!(
            [ {
              tenant_identifier: TENANT,
              facility_identifier: FACILITY,
              visit_type: "   ",
              system_of_record: "corvid",
              effective_on: Date.new(2020, 1, 1),
              expires_on: nil,
              created_at: now,
              updated_at: now
            } ]
          )
        end
      end
    end
  end

  test "database rejects overlapping all-visits ranges for the same tenant and facility" do
    now = Time.current
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 12, 31)
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Corvid::BillingSystemSetting.transaction(requires_new: true) do
          Corvid::BillingSystemSetting.insert_all!(
            [ {
              tenant_identifier: TENANT,
              facility_identifier: FACILITY,
              visit_type: nil,
              system_of_record: "ehr",
              effective_on: Date.new(2026, 6, 1),
              expires_on: nil,
              created_at: now,
              updated_at: now
            } ]
          )
        end
      end
    end
  end

  test "database rejects a range that starts on another range's last day" do
    now = Time.current
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Corvid::BillingSystemSetting.transaction(requires_new: true) do
          Corvid::BillingSystemSetting.insert_all!(
            [ {
              tenant_identifier: TENANT,
              facility_identifier: FACILITY,
              visit_type: nil,
              system_of_record: "ehr",
              effective_on: Date.new(2026, 6, 30),
              expires_on: nil,
              created_at: now,
              updated_at: now
            } ]
          )
        end
      end
    end
  end

  test "database rejects extending a range onto the next range's first day" do
    with_tenant(TENANT) do
      row1 = Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "ehr",
        effective_on: Date.new(2026, 7, 1),
        expires_on: nil
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        row1.update_columns(expires_on: Date.new(2026, 7, 1))
      end
    end
  end

  test "database rejects a dental range that starts on another dental range's last day" do
    now = Time.current
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: "dental",
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Corvid::BillingSystemSetting.transaction(requires_new: true) do
          Corvid::BillingSystemSetting.insert_all!(
            [ {
              tenant_identifier: TENANT,
              facility_identifier: FACILITY,
              visit_type: "dental",
              system_of_record: "ehr",
              effective_on: Date.new(2026, 6, 30),
              expires_on: nil,
              created_at: now,
              updated_at: now
            } ]
          )
        end
      end
    end
  end

  test "database allows a dental range starting on an all-visits range's last day" do
    now = Time.current
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )

      Corvid::BillingSystemSetting.transaction(requires_new: true) do
        Corvid::BillingSystemSetting.insert_all!(
          [ {
            tenant_identifier: TENANT,
            facility_identifier: FACILITY,
            visit_type: "dental",
            system_of_record: "ehr",
            effective_on: Date.new(2026, 6, 30),
            expires_on: nil,
            created_at: now,
            updated_at: now
          } ]
        )
      end

      assert_equal 2, Corvid::BillingSystemSetting.count
    end
  end

  test "database allows adjacent effective ranges for the same tenant facility and visit type" do
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )
      later = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "ehr",
        effective_on: Date.new(2026, 7, 1),
        expires_on: nil
      )
      assert later.valid?, later.errors.full_messages.join(", ")
      later.save!
    end
  end

  test "database allows the same effective range in another tenant facility or visit type" do
    window = {
      system_of_record: "corvid",
      effective_on: Date.new(2022, 1, 1),
      expires_on: Date.new(2025, 12, 31)
    }

    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(facility_identifier: FACILITY, visit_type: nil, **window)
      Corvid::BillingSystemSetting.create!(facility_identifier: FACILITY, visit_type: "dental", **window)
      Corvid::BillingSystemSetting.create!(facility_identifier: OTHER_FACILITY, visit_type: nil, **window)
    end

    with_tenant(OTHER_TENANT) do
      Corvid::BillingSystemSetting.create!(facility_identifier: FACILITY, visit_type: nil, **window)
    end

    assert_equal 4, Corvid::BillingSystemSetting.unscoped.count
  end

  # -- Model validations -----------------------------------------------------

  test "requires tenant_identifier facility_identifier system_of_record and effective_on" do
    with_tenant(TENANT) do
      row = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1)
      )
      row.tenant_identifier = nil
      refute row.valid?
      assert row.errors[:tenant_identifier].any?

      row = Corvid::BillingSystemSetting.new(
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1)
      )
      refute row.valid?
      assert row.errors[:facility_identifier].any?

      row = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        effective_on: Date.new(2020, 1, 1)
      )
      refute row.valid?
      assert row.errors[:system_of_record].any?

      row = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        system_of_record: "corvid"
      )
      refute row.valid?
      assert row.errors[:effective_on].any?
    end
  end

  test "rejects system_of_record outside corvid and ehr" do
    with_tenant(TENANT) do
      row = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        system_of_record: "clearinghouse",
        effective_on: Date.new(2020, 1, 1)
      )
      refute row.valid?
      assert row.errors[:system_of_record].any?
    end
  end

  test "rejects expires_on before effective_on" do
    with_tenant(TENANT) do
      row = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        system_of_record: "corvid",
        effective_on: Date.new(2024, 6, 1),
        expires_on: Date.new(2024, 5, 1)
      )
      refute row.valid?
      assert row.errors[:expires_on].any?
    end
  end

  test "visit_type must be nil or non-blank" do
    with_tenant(TENANT) do
      blank = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        visit_type: "  ",
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1)
      )
      refute blank.valid?
      assert blank.errors[:visit_type].any?

      ok = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        visit_type: "dental",
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1)
      )
      assert ok.valid?
    end
  end

  test "overlapping range for the same tenant facility and visit type is invalid on effective_on" do
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: "dental",
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )

      overlap = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        visit_type: "dental",
        system_of_record: "ehr",
        effective_on: Date.new(2026, 1, 1),
        expires_on: nil
      )
      refute overlap.valid?
      assert overlap.errors[:effective_on].any?
    end
  end

  test "range starting on another range's last day is invalid on effective_on" do
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )

      boundary = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "ehr",
        effective_on: Date.new(2026, 6, 30),
        expires_on: nil
      )
      refute boundary.valid?
      assert boundary.errors[:effective_on].any?
    end
  end

  test "dental range starting on another dental range's last day is invalid on effective_on" do
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: "dental",
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )

      boundary = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        visit_type: "dental",
        system_of_record: "ehr",
        effective_on: Date.new(2026, 6, 30),
        expires_on: nil
      )
      refute boundary.valid?
      assert boundary.errors[:effective_on].any?
    end
  end

  test "dental range starting on an all-visits range's last day is valid" do
    with_tenant(TENANT) do
      Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        visit_type: nil,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2026, 6, 30)
      )

      boundary = Corvid::BillingSystemSetting.new(
        facility_identifier: FACILITY,
        visit_type: "dental",
        system_of_record: "ehr",
        effective_on: Date.new(2026, 6, 30),
        expires_on: nil
      )
      assert boundary.valid?, boundary.errors.full_messages.join(", ")
    end
  end

  # -- TenantScoped ----------------------------------------------------------

  test "includes TenantScoped and scopes queries to the current tenant" do
    assert_includes Corvid::BillingSystemSetting.included_modules, Corvid::TenantScoped

    in_tenant = nil
    outside = nil

    with_tenant(TENANT) do
      in_tenant = record_system_of_record(facility_identifier: FACILITY)
    end
    with_tenant(OTHER_TENANT) do
      outside = record_system_of_record(facility_identifier: FACILITY, system_of_record: "ehr")
    end

    with_tenant(TENANT) do
      visible = Corvid::BillingSystemSetting.all
      assert_includes visible, in_tenant
      refute_includes visible, outside
    end
  end

  test "queries without tenant context raise" do
    assert_raises(Corvid::MissingTenantContextError) do
      Corvid::BillingSystemSetting.first
    end
  end

  test "defaults tenant_identifier from context" do
    with_tenant(TENANT) do
      row = Corvid::BillingSystemSetting.create!(
        facility_identifier: FACILITY,
        system_of_record: "corvid",
        effective_on: Date.new(2020, 1, 1)
      )
      assert_equal TENANT, row.tenant_identifier
    end
  end

  # -- system_of_record_for --------------------------------------------------

  test "system_of_record_for returns unknown when on is not a Date" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY)
      assert_equal :unknown,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: nil
        )
      assert_equal :unknown,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: "2025-01-01"
        )
    end
  end

  test "system_of_record_for returns unknown when facility_identifier is blank" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY)
      assert_equal :unknown,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: nil, visit_type: nil, on: Date.new(2025, 1, 1)
        )
      assert_equal :unknown,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: "  ", visit_type: nil, on: Date.new(2025, 1, 1)
        )
    end
  end

  test "system_of_record_for reads only rows effective on the given date" do
    with_tenant(TENANT) do
      record_system_of_record(
        facility_identifier: FACILITY,
        system_of_record: "corvid",
        effective_on: Date.new(2025, 1, 1),
        expires_on: Date.new(2025, 6, 30)
      )
      record_system_of_record(
        facility_identifier: FACILITY,
        system_of_record: "ehr",
        effective_on: Date.new(2025, 7, 1),
        expires_on: nil
      )

      assert_equal :corvid,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: Date.new(2025, 3, 15)
        )
      assert_equal :ehr,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: Date.new(2025, 8, 1)
        )
      assert_equal :unknown,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: Date.new(2024, 12, 31)
        )
    end
  end

  test "system_of_record_for ignores another tenant's rows" do
    with_tenant(OTHER_TENANT) do
      record_system_of_record(facility_identifier: FACILITY, system_of_record: "ehr")
    end

    with_tenant(TENANT) do
      assert_equal :unknown,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: Date.new(2025, 1, 1)
        )
    end
  end

  test "system_of_record_for prefers visit-type row when visit_type is given" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY, system_of_record: "ehr")
      record_system_of_record(
        facility_identifier: FACILITY, visit_type: "dental", system_of_record: "corvid"
      )

      assert_equal :corvid,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: "dental", on: Date.new(2025, 1, 1)
        )
      assert_equal :ehr,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: "behavioral_health", on: Date.new(2025, 1, 1)
        )
    end
  end

  test "system_of_record_for with nil visit_type uses all-visits row unless a visit-type row names a different system" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY, system_of_record: "corvid")
      record_system_of_record(
        facility_identifier: FACILITY, visit_type: "dental", system_of_record: "ehr"
      )

      assert_equal :unknown,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: Date.new(2025, 1, 1)
        )
    end
  end

  test "system_of_record_for with nil visit_type stays corvid when visit-type row matches all-visits system" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY, system_of_record: "corvid")
      record_system_of_record(
        facility_identifier: FACILITY, visit_type: "dental", system_of_record: "corvid"
      )

      assert_equal :corvid,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: Date.new(2025, 1, 1)
        )
    end
  end

  test "system_of_record_for with nil visit_type is unknown when only visit-type rows exist" do
    with_tenant(TENANT) do
      record_system_of_record(
        facility_identifier: FACILITY, visit_type: "dental", system_of_record: "corvid"
      )

      assert_equal :corvid,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: "dental", on: Date.new(2025, 1, 1)
        )
      assert_equal :unknown,
        Corvid::BillingSystemSetting.system_of_record_for(
          facility_identifier: FACILITY, visit_type: nil, on: Date.new(2025, 1, 1)
        )
    end
  end
end
