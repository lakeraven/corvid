# frozen_string_literal: true

require "test_helper"
require "rake"

# Asserts the NPPES crosswalk import behaves as a per-release snapshot:
# a re-import of the same release_label replaces the prior snapshot so
# that rows CMS dropped from the file don't linger in the DB.
class CmsNppesRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["cms:nppes:import_crosswalk"].reenable
    @tmpdir = Dir.mktmpdir
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
  end

  test "import_crosswalk loads canonical CSV rows tagged with the release label" do
    path = File.join(@tmpdir, "crosswalk.csv")
    File.write(path, <<~CSV)
      npi,ccn,effective_date,end_date
      1234567890,451301,2015-01-01,
      9876543210,451999,2020-01-01,2024-12-31
    CSV

    Rake::Task["cms:nppes:import_crosswalk"].invoke(path, "nppes_2026_q1")

    rows = Corvid::NpiCcnCrosswalk.where(source_release: "nppes_2026_q1").order(:npi)
    assert_equal 2, rows.count
    assert_equal "451301", rows.find_by(npi: "1234567890").ccn
    assert_equal Date.new(2024, 12, 31),
                 rows.find_by(npi: "9876543210").end_date
  end

  test "import_crosswalk replaces the snapshot when re-run with the same release label" do
    first = File.join(@tmpdir, "first.csv")
    File.write(first, <<~CSV)
      npi,ccn,effective_date,end_date
      1234567890,451301,2015-01-01,
      9876543210,451999,2020-01-01,
    CSV
    Rake::Task["cms:nppes:import_crosswalk"].invoke(first, "nppes_2026_q1")
    Rake::Task["cms:nppes:import_crosswalk"].reenable
    assert_equal 2, Corvid::NpiCcnCrosswalk.where(source_release: "nppes_2026_q1").count

    # CMS dropped 9876543210 and added a new row; re-importing under
    # the same label must reflect the new snapshot exactly.
    second = File.join(@tmpdir, "second.csv")
    File.write(second, <<~CSV)
      npi,ccn,effective_date,end_date
      1234567890,451301,2015-01-01,
      5555555555,452000,2024-01-01,
    CSV
    Rake::Task["cms:nppes:import_crosswalk"].invoke(second, "nppes_2026_q1")

    snapshot = Corvid::NpiCcnCrosswalk.where(source_release: "nppes_2026_q1")
    assert_equal 2, snapshot.count
    assert_nil snapshot.find_by(npi: "9876543210"),
               "dropped NPI must not linger in DB after snapshot replacement"
    refute_nil snapshot.find_by(npi: "5555555555")
  end

  test "import_crosswalk leaves other release-label snapshots untouched" do
    older = File.join(@tmpdir, "older.csv")
    File.write(older, "npi,ccn,effective_date,end_date\n1234567890,451301,2015-01-01,\n")
    Rake::Task["cms:nppes:import_crosswalk"].invoke(older, "nppes_2025_q4")
    Rake::Task["cms:nppes:import_crosswalk"].reenable

    newer = File.join(@tmpdir, "newer.csv")
    File.write(newer, "npi,ccn,effective_date,end_date\n9876543210,451999,2020-01-01,\n")
    Rake::Task["cms:nppes:import_crosswalk"].invoke(newer, "nppes_2026_q1")

    assert_equal 1, Corvid::NpiCcnCrosswalk.where(source_release: "nppes_2025_q4").count
    assert_equal 1, Corvid::NpiCcnCrosswalk.where(source_release: "nppes_2026_q1").count
  end

  test "import_crosswalk aborts when given a missing file" do
    assert_raises(SystemExit) do
      Rake::Task["cms:nppes:import_crosswalk"].invoke("/no/such/file.csv", "label")
    end
  end
end
