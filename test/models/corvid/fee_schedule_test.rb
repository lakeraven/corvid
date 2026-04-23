# frozen_string_literal: true

require "test_helper"

class Corvid::FeeScheduleTest < ActiveSupport::TestCase
  TENANT = "tnt_fs_test"

  setup do
    Corvid::FeeSchedule.unscoped.delete_all
  end

  # =============================================================================
  # CREATION & DEFAULTS
  # =============================================================================

  test "creates with name" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.create!(
        name: "Standard Sliding Fee",
        facility_identifier: "fac_test",
        program: "general"
      )
      assert fs.persisted?
    end
  end

  test "defaults to active" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.create!(name: "Test", facility_identifier: "fac_test")
      assert fs.active?
    end
  end

  # =============================================================================
  # VALIDATIONS
  # =============================================================================

  test "requires name" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.new(name: nil)
      refute fs.valid?
      assert fs.errors[:name].any?
    end
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "current scope returns active schedules" do
    with_tenant(TENANT) do
      active = Corvid::FeeSchedule.create!(name: "Active", facility_identifier: "fac_test", active: true)
      inactive = Corvid::FeeSchedule.create!(name: "Inactive", facility_identifier: "fac_test", active: false)

      assert_includes Corvid::FeeSchedule.current, active
      refute_includes Corvid::FeeSchedule.current, inactive
    end
  end

  test "current scope respects effective_date" do
    with_tenant(TENANT) do
      current = Corvid::FeeSchedule.create!(
        name: "Current",
        facility_identifier: "fac_test",
        active: true,
        effective_date: 1.month.ago
      )
      future = Corvid::FeeSchedule.create!(
        name: "Future",
        facility_identifier: "fac_test",
        active: true,
        effective_date: 1.month.from_now
      )

      assert_includes Corvid::FeeSchedule.current, current
      refute_includes Corvid::FeeSchedule.current, future
    end
  end

  test "current scope includes schedules with nil effective_date" do
    with_tenant(TENANT) do
      no_date = Corvid::FeeSchedule.create!(
        name: "No Date",
        facility_identifier: "fac_test",
        active: true,
        effective_date: nil
      )
      assert_includes Corvid::FeeSchedule.current, no_date
    end
  end

  # =============================================================================
  # FIELDS
  # =============================================================================

  test "stores program" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.create!(name: "Test", facility_identifier: "fac_test", program: "dental")
      assert_equal "dental", fs.program
    end
  end

  test "stores effective_date and end_date" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.create!(
        name: "FY2026",
        facility_identifier: "fac_test",
        effective_date: Date.new(2025, 10, 1),
        end_date: Date.new(2026, 9, 30)
      )
      assert_equal Date.new(2025, 10, 1), fs.effective_date
      assert_equal Date.new(2026, 9, 30), fs.end_date
    end
  end

  # =============================================================================
  # MULTI-TENANCY
  # =============================================================================

  test "fee schedules scoped to tenant" do
    mine = nil
    other = nil

    with_tenant("tenant_a") do
      mine = Corvid::FeeSchedule.create!(name: "Mine", facility_identifier: "fac_test")
    end
    with_tenant("tenant_b") do
      other = Corvid::FeeSchedule.create!(name: "Other", facility_identifier: "fac_test")
    end

    with_tenant("tenant_a") do
      assert_includes Corvid::FeeSchedule.all, mine
      refute_includes Corvid::FeeSchedule.all, other
    end
  end
end
