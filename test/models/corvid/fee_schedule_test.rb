# frozen_string_literal: true

require "test_helper"

class Corvid::FeeScheduleTest < ActiveSupport::TestCase
  TENANT = "tnt_fs_test"

  setup do
    Corvid::FeeSchedule.unscoped.delete_all
  end

  test "creates with name" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.create!(
        name: "Standard Sliding Fee",
        facility_identifier: "fac_test",
        program: "general",
        effective_date: Date.current,
        active: true
      )
      assert fs.persisted?
    end
  end

  test "requires name" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.new(name: nil, program: "general", effective_date: Date.current)
      refute fs.valid?
      assert fs.errors[:name].any?
    end
  end

  test "requires program" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.new(name: "Standard", program: nil, effective_date: Date.current)
      refute fs.valid?
      assert fs.errors[:program].any?
    end
  end

  test "requires effective_date" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.new(name: "Standard", program: "general", effective_date: nil)
      refute fs.valid?
      assert fs.errors[:effective_date].any?
    end
  end

  test "end_date must be after effective_date" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.new(
        name: "Standard", program: "general",
        effective_date: Date.current, end_date: 1.day.ago.to_date
      )
      refute fs.valid?
      assert fs.errors[:end_date].any?
    end
  end

  # -- Defaults ---------------------------------------------------------------

  test "defaults to active" do
    with_tenant(TENANT) do
      fs = create_schedule
      assert fs.active?
    end
  end

  test "current scope returns active schedules" do
    with_tenant(TENANT) do
      active = create_schedule(name: "Active")
      inactive = create_schedule(name: "Inactive", active: false)

      assert_includes Corvid::FeeSchedule.current, active
      refute_includes Corvid::FeeSchedule.current, inactive
    end
  end

  test "defaults tiers to empty array via adapter" do
    with_tenant(TENANT) do
      fs = create_schedule
      assert_equal [], fs.tiers
    end
  end

  test "active scope returns only active schedules" do
    with_tenant(TENANT) do
      active = create_schedule(name: "Active", active: true)
      inactive = create_schedule(name: "Inactive", active: false)

      results = Corvid::FeeSchedule.current
      assert_includes results, active
      refute_includes results, inactive
    end
  end

  # -- Scopes -----------------------------------------------------------------

  test "for_program filters by program" do
    with_tenant(TENANT) do
      immun = create_schedule(name: "Immunization", program: "immunization")
      create_schedule(name: "General", program: "general")

      results = Corvid::FeeSchedule.for_program("immunization")
      assert_equal [immun], results.to_a
    end
  end

  # -- Discount calculation ---------------------------------------------------

  test "discount_for_fpl returns correct discount percentage" do
    with_tenant(TENANT) do
      tiers_data = [
        { "fpl_max" => 100, "discount_percent" => 100 },
        { "fpl_max" => 150, "discount_percent" => 75 },
        { "fpl_max" => 200, "discount_percent" => 50 },
        { "fpl_max" => 250, "discount_percent" => 25 }
      ]
      fs = build_schedule_with_tiers(tiers_data)

      assert_equal 100, fs.discount_for_fpl(80)
      assert_equal 100, fs.discount_for_fpl(100)
      assert_equal 75, fs.discount_for_fpl(120)
      assert_equal 50, fs.discount_for_fpl(180)
      assert_equal 25, fs.discount_for_fpl(220)
      assert_equal 0, fs.discount_for_fpl(300)
    end
  end

  test "discount_for_fpl returns 0 with no tiers" do
    with_tenant(TENANT) do
      fs = build_schedule_with_tiers([])
      assert_equal 0, fs.discount_for_fpl(150)
    end
  end

  test "apply_discount calculates discounted amount" do
    with_tenant(TENANT) do
      tiers_data = [
        { "fpl_max" => 100, "discount_percent" => 100 },
        { "fpl_max" => 150, "discount_percent" => 75 },
        { "fpl_max" => 200, "discount_percent" => 50 }
      ]
      fs = build_schedule_with_tiers(tiers_data)

      assert_equal 0, fs.apply_discount(100.0, fpl_percent: 80)
      assert_equal 25.0, fs.apply_discount(100.0, fpl_percent: 120)
      assert_equal 50.0, fs.apply_discount(100.0, fpl_percent: 180)
      assert_equal 100.0, fs.apply_discount(100.0, fpl_percent: 300)
    end
  end

  # -- for_patient_visit ------------------------------------------------------

  test "for_patient_visit finds active schedule for program" do
    with_tenant(TENANT) do
      fs = create_schedule(name: "Immunization", program: "immunization")

      found = Corvid::FeeSchedule.for_patient_visit(program: "immunization")
      assert_equal fs, found
    end
  end

  # -- current with date range ------------------------------------------------

  test "current returns active schedules within effective period" do
    with_tenant(TENANT) do
      current = create_schedule(name: "Current", effective_date: 30.days.ago.to_date, end_date: 30.days.from_now.to_date)
      expired = Corvid::FeeSchedule.create!(
        name: "Expired", program: "general",
        effective_date: 90.days.ago.to_date, end_date: 30.days.ago.to_date,
        facility_identifier: "fac_test"
      )

      results = Corvid::FeeSchedule.current
      assert_includes results, current
    end
  end

  private

  def create_schedule(name: "Standard", program: "general", active: true, **attrs)
    Corvid::FeeSchedule.create!(
      name: name,
      facility_identifier: "fac_test",
      program: program,
      effective_date: attrs.delete(:effective_date) || 30.days.ago.to_date,
      active: active,
      **attrs
    )
  end

  def build_schedule_with_tiers(tiers_data)
    fs = Corvid::FeeSchedule.new(name: "Test", program: "general", effective_date: Date.current)
    # Override read_tiers to return our data directly
    fs.define_singleton_method(:read_tiers) { tiers_data }
    fs
  end
end
