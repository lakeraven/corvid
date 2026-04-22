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
        active: true
      )
      assert fs.persisted?
    end
  end

  test "requires name" do
    with_tenant(TENANT) do
      fs = Corvid::FeeSchedule.new(name: nil)
      refute fs.valid?
    end
  end

  test "current scope returns active schedules" do
    with_tenant(TENANT) do
      active = Corvid::FeeSchedule.create!(name: "Active", facility_identifier: "fac_test", active: true)
      inactive = Corvid::FeeSchedule.create!(name: "Inactive", facility_identifier: "fac_test", active: false)

      assert_includes Corvid::FeeSchedule.current, active
      refute_includes Corvid::FeeSchedule.current, inactive
    end
  end
end
