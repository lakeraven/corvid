# frozen_string_literal: true

require "test_helper"
require "stringio"

class Corvid::CmsSnapshotTest < ActiveSupport::TestCase
  # Snapshot service is global lookup data, not tenant-scoped.
  # Tests use a separate teardown to keep the table clean.

  def setup
    Corvid::FeeScheduleEntry.connection.execute("TRUNCATE corvid_fee_schedule_entries")
  end

  def teardown
    Corvid::FeeScheduleEntry.connection.execute("TRUNCATE corvid_fee_schedule_entries")
  end

  # -- Header contract -------------------------------------------------------

  test "HEADERS is the canonical column list and order" do
    expected = %w[
      cpt_code locality effective_date
      work_rvu pe_rvu mp_rvu
      work_gpci pe_gpci mp_gpci
      conversion_factor
    ]
    assert_equal expected, Corvid::CmsSnapshot::HEADERS
  end

  # -- Roundtrip -------------------------------------------------------------

  test "export_csv then import_csv roundtrips all rows" do
    seed_three_rows!

    io = StringIO.new
    rows_written = Corvid::CmsSnapshot.export_csv(io)
    assert_equal 3, rows_written

    Corvid::FeeScheduleEntry.connection.execute("TRUNCATE corvid_fee_schedule_entries")
    assert_equal 0, Corvid::FeeScheduleEntry.unscoped.count

    io.rewind
    rows_loaded = Corvid::CmsSnapshot.import_csv(io)
    assert_equal 3, rows_loaded
    assert_equal 3, Corvid::FeeScheduleEntry.unscoped.count
  end

  test "exported snapshot starts with the canonical header row" do
    seed_three_rows!

    io = StringIO.new
    Corvid::CmsSnapshot.export_csv(io)
    io.rewind

    first_line = io.gets&.chomp
    assert_equal Corvid::CmsSnapshot::HEADERS.join(","), first_line
  end

  test "exported snapshot is deterministic (same DB content = same bytes)" do
    seed_three_rows!

    a = StringIO.new
    Corvid::CmsSnapshot.export_csv(a)

    b = StringIO.new
    Corvid::CmsSnapshot.export_csv(b)

    assert_equal a.string, b.string,
                 "two exports of the same DB content must produce identical bytes"
  end

  test "exported rows are ordered by (effective_date, cpt_code, locality)" do
    Corvid::FeeScheduleEntry.create!(
      cpt_code: "99214", locality: "01", effective_date: Date.new(2025, 1, 1),
      work_rvu: 1.0, pe_rvu: 1.0, mp_rvu: 0.1,
      work_gpci: 1.0, pe_gpci: 1.0, mp_gpci: 1.0,
      conversion_factor: 32.74
    )
    Corvid::FeeScheduleEntry.create!(
      cpt_code: "99213", locality: "01", effective_date: Date.new(2024, 1, 1),
      work_rvu: 1.0, pe_rvu: 1.0, mp_rvu: 0.1,
      work_gpci: 1.0, pe_gpci: 1.0, mp_gpci: 1.0,
      conversion_factor: 32.74
    )
    Corvid::FeeScheduleEntry.create!(
      cpt_code: "99213", locality: "00", effective_date: Date.new(2025, 1, 1),
      work_rvu: 1.0, pe_rvu: 1.0, mp_rvu: 0.1,
      work_gpci: 1.0, pe_gpci: 1.0, mp_gpci: 1.0,
      conversion_factor: 32.74
    )

    io = StringIO.new
    Corvid::CmsSnapshot.export_csv(io)
    io.rewind
    io.gets # skip header
    cpts_and_dates = io.readlines.map { |line| line.split(",")[0..2] }

    assert_equal [
      [ "99213", "01", "2024-01-01" ], # earliest date first
      [ "99213", "00", "2025-01-01" ], # 2025 group sorted by cpt then locality
      [ "99214", "01", "2025-01-01" ]
    ], cpts_and_dates
  end

  # -- Import edge cases -----------------------------------------------------

  test "import_csv truncates before loading (idempotent re-load)" do
    seed_three_rows!

    io = StringIO.new
    Corvid::CmsSnapshot.export_csv(io)
    io.rewind

    Corvid::CmsSnapshot.import_csv(io)
    assert_equal 3, Corvid::FeeScheduleEntry.unscoped.count

    # Re-import: should still be 3 (truncate), not 6.
    io.rewind
    Corvid::CmsSnapshot.import_csv(io)
    assert_equal 3, Corvid::FeeScheduleEntry.unscoped.count
  end

  test "import_csv rejects snapshots with mismatched headers" do
    io = StringIO.new("cpt_code,wrong_column\n99213,01\n")
    assert_raises(ArgumentError) do
      Corvid::CmsSnapshot.import_csv(io)
    end
  end

  # -- Checksum --------------------------------------------------------------

  test "checksum_io returns the SHA256 hex digest of the IO contents" do
    io = StringIO.new("hello world")
    digest = Corvid::CmsSnapshot.checksum_io(io)
    assert_equal "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9", digest
  end

  test "checksum_io is stable across two reads of the same content" do
    a = Corvid::CmsSnapshot.checksum_io(StringIO.new("identical bytes"))
    b = Corvid::CmsSnapshot.checksum_io(StringIO.new("identical bytes"))
    assert_equal a, b
  end

  private

  def seed_three_rows!
    [
      [ "99213", "01", Date.new(2025, 1, 1) ],
      [ "99214", "01", Date.new(2025, 1, 1) ],
      [ "99215", "01", Date.new(2025, 1, 1) ]
    ].each do |cpt, locality, date|
      Corvid::FeeScheduleEntry.create!(
        cpt_code: cpt, locality: locality, effective_date: date,
        work_rvu: 1.5, pe_rvu: 1.0, mp_rvu: 0.1,
        work_gpci: 1.0, pe_gpci: 0.95, mp_gpci: 0.7,
        conversion_factor: 32.7400
      )
    end
  end
end
