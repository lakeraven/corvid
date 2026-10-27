# frozen_string_literal: true

require "test_helper"
require "rake"

# Asserts cms:zip_cbsa:import replaces a full fiscal-year snapshot in one
# transaction, matching the cms:ipps import task pattern.
class CmsZipCbsaRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["cms:zip_cbsa:import"].reenable
    @tmpdir = Dir.mktmpdir
    cleanup_zip_cbsa_crosswalk_rows!
  end

  teardown do
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    cleanup_zip_cbsa_crosswalk_rows!
  end

  def cleanup_zip_cbsa_crosswalk_rows!
    return unless Corvid.const_defined?(:ZipCbsaCrosswalk, false)

    Corvid::ZipCbsaCrosswalk.unscoped.delete_all
  rescue ActiveRecord::StatementInvalid
    nil
  end

  test "import loads canonical CSV rows tagged with the release label" do
    path = File.join(@tmpdir, "crosswalk.csv")
    File.write(path, <<~CSV)
      zip,cbsa
      88101,98765
      88202,12
    CSV

    assert_output(/Imported 2/) do
      Rake::Task["cms:zip_cbsa:import"].invoke("2026", path, "synthetic_fy2026")
    end

    rows = Corvid::ZipCbsaCrosswalk.where(fiscal_year: 2026).order(:zip)
    assert_equal 2, rows.count
    assert_equal "98765", rows.find_by(zip: "88101").cbsa
    assert_equal "synthetic_fy2026", rows.find_by(zip: "88101").release_label
    assert_equal "12", rows.find_by(zip: "88202").cbsa
  end

  test "import replaces the entire fiscal-year snapshot" do
    first = File.join(@tmpdir, "first.csv")
    File.write(first, "zip,cbsa\n88101,98765\n88202,12\n")
    Rake::Task["cms:zip_cbsa:import"].invoke("2026", first, "v1")
    Rake::Task["cms:zip_cbsa:import"].reenable

    second = File.join(@tmpdir, "second.csv")
    File.write(second, "zip,cbsa\n88101,11111\n")
    Rake::Task["cms:zip_cbsa:import"].invoke("2026", second, "v2")

    fy = Corvid::ZipCbsaCrosswalk.where(fiscal_year: 2026)
    assert_equal 1, fy.count
    assert_nil fy.find_by(zip: "88202"),
               "removed zip must be gone after a corrected import"
    assert_equal "11111", fy.find_by(zip: "88101").cbsa
    assert_equal "v2", fy.find_by(zip: "88101").release_label
  end

  test "import skips release-style comment lines" do
    path = File.join(@tmpdir, "crosswalk.csv")
    File.write(path, "# release_label: test\nzip,cbsa\n88101,98765\n")
    assert_output(/Imported 1/) do
      Rake::Task["cms:zip_cbsa:import"].invoke("2026", path, "test")
    end

    assert_equal "98765", Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "88101").cbsa
  end

  test "import aborts when given a missing file" do
    assert_raises(SystemExit) do
      Rake::Task["cms:zip_cbsa:import"].invoke("2026", "/no/such/file.csv", "label")
    end
  end

  test "import aborts with usage when required arguments are missing" do
    assert_raises(SystemExit) do
      Rake::Task["cms:zip_cbsa:import"].invoke
    end
  end
end
