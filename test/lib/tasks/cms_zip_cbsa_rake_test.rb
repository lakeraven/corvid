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
  end

  def write_crosswalk_csv(name, body)
    path = File.join(@tmpdir, name)
    File.write(path, body)
    path
  end

  def seed_fy2026_row!
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88101", cbsa: "98765", release_label: "seed"
    )
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

  test "import aborts on header-only CSV and leaves the fiscal year snapshot untouched" do
    seed_fy2026_row!
    path = write_crosswalk_csv("header_only.csv", "zip,cbsa\n")

    assert_raises(SystemExit) do
      Rake::Task["cms:zip_cbsa:import"].invoke("2026", path, "empty")
    end

    assert_equal 1, Corvid::ZipCbsaCrosswalk.where(fiscal_year: 2026).count
    assert_equal "98765", Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "88101").cbsa
  end

  test "import aborts on comments plus header with no data rows and leaves snapshot untouched" do
    seed_fy2026_row!
    path = write_crosswalk_csv("comments_header.csv", "# release_label: noop\nzip,cbsa\n")

    assert_raises(SystemExit) do
      Rake::Task["cms:zip_cbsa:import"].invoke("2026", path, "empty")
    end

    assert_equal 1, Corvid::ZipCbsaCrosswalk.where(fiscal_year: 2026).count
  end

  %w[abc 26 2026x 0 2O26].each do |bad_year|
    test "import aborts with usage for invalid fiscal year #{bad_year.inspect} and writes nothing" do
      seed_fy2026_row!
      path = write_crosswalk_csv("valid.csv", "zip,cbsa\n88101,11111\n")

      assert_raises(SystemExit) do
        Rake::Task["cms:zip_cbsa:import"].invoke(bad_year, path, "bad_year")
      end
      Rake::Task["cms:zip_cbsa:import"].reenable

      assert_equal "98765", Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "88101").cbsa
      assert_nil Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "88101", cbsa: "11111")
    end
  end

  test "import rolls back when insert_all fails after delete (transactional snapshot replace)" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88101", cbsa: "98765", release_label: "keep"
    )
    path = write_crosswalk_csv("replace.csv", "zip,cbsa\n88202,12\n")

    boom = Class.new(StandardError)
    Corvid::ZipCbsaCrosswalk.stub(:insert_all, ->(*) { raise boom, "insert failed" }) do
      assert_raises(boom) do
        Rake::Task["cms:zip_cbsa:import"].invoke("2026", path, "boom")
      end
    end
    Rake::Task["cms:zip_cbsa:import"].reenable

    row = Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "88101")
    assert_equal "98765", row.cbsa
    assert_equal "keep", row.release_label
    assert_nil Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "88202")
  end

  test "import accepts a UTF-8 BOM before the header row" do
    path = File.join(@tmpdir, "bom.csv")
    File.binwrite(path, "\xEF\xBB\xBFzip,cbsa\n88101,98765\n")

    assert_output(/Imported 1/) do
      Rake::Task["cms:zip_cbsa:import"].invoke("2026", path, "bom")
    end

    assert_equal "98765", Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "88101").cbsa
  end

  test "import defaults release_label to manual when the third argument is omitted" do
    path = write_crosswalk_csv("manual_label.csv", "zip,cbsa\n88101,98765\n")

    assert_output(/Imported 1/) do
      Rake::Task["cms:zip_cbsa:import"].invoke("2026", path)
    end

    assert_equal "manual", Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "88101").release_label
  end

  test "import imports a zip with a leading zero" do
    path = write_crosswalk_csv("leading_zero.csv", "zip,cbsa\n01234,98765\n")

    assert_output(/Imported 1/) do
      Rake::Task["cms:zip_cbsa:import"].invoke("2026", path, "leading_zero")
    end

    assert_equal "98765", Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "01234").cbsa
  end
end
