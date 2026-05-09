# frozen_string_literal: true

require "test_helper"
require "rake"

# Asserts the rake import tasks behave as full-FY snapshot replacements
# rather than per-row replacements — when a corrected CMS file removes
# a DRG / locality, the old DB row must be removed too.
class CmsIppsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["cms:ipps:import_drg_weights"].reenable
    Rake::Task["cms:ipps:import_hospital_rates"].reenable

    @tmpdir = Dir.mktmpdir
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
  end

  test "import_drg_weights replaces the entire fiscal-year snapshot" do
    first = File.join(@tmpdir, "drg_first.csv")
    File.write(first, "drg_code,relative_weight\n470,2.07\n469,3.68\n287,0.92\n")
    Rake::Task["cms:ipps:import_drg_weights"].invoke("2026", first)
    Rake::Task["cms:ipps:import_drg_weights"].reenable

    assert_equal 3, Corvid::IppsDrgWeight.where(fiscal_year: 2026).count

    # Corrected file: DRG 287 removed (e.g., CMS retired the code),
    # 470 weight bumped, 469 unchanged.
    second = File.join(@tmpdir, "drg_corrected.csv")
    File.write(second, "drg_code,relative_weight\n470,2.10\n469,3.68\n")
    Rake::Task["cms:ipps:import_drg_weights"].invoke("2026", second)

    fy = Corvid::IppsDrgWeight.where(fiscal_year: 2026)
    assert_equal 2, fy.count, "removed DRG 287 must be gone after a corrected import"
    assert_nil fy.find_by(drg_code: "287"),
               "stale DRG row would let the rate provider keep using it"
    assert_equal BigDecimal("2.10"),
                 fy.find_by(drg_code: "470").relative_weight,
                 "updated weight propagates"
  end

  test "import_hospital_rates replaces the entire fiscal-year snapshot" do
    first = File.join(@tmpdir, "hosp_first.csv")
    File.write(first, "locality,base_rate,wage_index\nNATIONAL,6500.00,1.0\n01,6500.00,1.085\n02,6500.00,0.94\n")
    Rake::Task["cms:ipps:import_hospital_rates"].invoke("2026", first)
    Rake::Task["cms:ipps:import_hospital_rates"].reenable

    assert_equal 3, Corvid::IppsHospitalRate.where(fiscal_year: 2026).count

    second = File.join(@tmpdir, "hosp_corrected.csv")
    File.write(second, "locality,base_rate,wage_index\nNATIONAL,6500.00,1.0\n01,6500.00,1.10\n")
    Rake::Task["cms:ipps:import_hospital_rates"].invoke("2026", second)

    fy = Corvid::IppsHospitalRate.where(fiscal_year: 2026)
    assert_equal 2, fy.count
    assert_nil fy.find_by(locality: "02"),
               "removed locality 02 must be gone after a corrected import"
  end
end
