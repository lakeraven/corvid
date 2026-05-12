# frozen_string_literal: true

require "test_helper"

class Corvid::CmsFacilityListParserTest < ActiveSupport::TestCase
  test "parses required columns into row hashes" do
    csv = <<~CSV
      ccn,npi,facility_name,effective_date,end_date
      451301,1234567890,Test Critical Access Hospital,2015-01-01,
      451302,,Another CAH,2020-06-15,2023-12-31
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "cms_cah_2025q4")

    assert_equal 2, result[:rows].size
    assert_empty result[:rejects]
    assert_equal "451301", result[:rows][0][:ccn]
    assert_equal "1234567890", result[:rows][0][:npi]
    assert_equal "Test Critical Access Hospital", result[:rows][0][:facility_name]
    assert_equal Date.new(2015, 1, 1), result[:rows][0][:effective_date]
    assert_nil result[:rows][0][:end_date]
    assert_equal "cms_cah_2025q4", result[:rows][0][:source_release]

    assert_nil result[:rows][1][:npi], "blank npi normalizes to nil via .presence"
    assert_equal Date.new(2023, 12, 31), result[:rows][1][:end_date]
  end

  test "skips comment lines so a release_label marker can ride on the file" do
    csv = <<~CSV
      # release_label: cms_cah_2025q4
      ccn,effective_date
      451301,2015-01-01
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "cms_cah_2025q4")
    assert_equal 1, result[:rows].size
    assert_equal "451301", result[:rows][0][:ccn]
  end

  test "raises ArgumentError when required columns are missing" do
    csv = <<~CSV
      ccn,facility_name
      451301,Test CAH
    CSV
    assert_raises(ArgumentError) do
      Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    end
  end

  test "accepts NPI-only rows (no ccn column needed)" do
    csv = <<~CSV
      npi,effective_date,facility_name
      1234567890,2015-01-01,NPI-Keyed CAH
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_nil result[:rows][0][:ccn]
    assert_equal "1234567890", result[:rows][0][:npi]
    assert_empty result[:rejects]
  end

  test "rows missing both ccn and npi are rejected with a clear reason" do
    csv = <<~CSV
      ccn,npi,effective_date
      ,,2015-01-01
      451301,,2015-01-02
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_equal 1, result[:rejects].size
    assert_match(/at least one of ccn or npi/, result[:rejects][0][:reason])
  end

  # -- Per-row rejects (permissive-but-report, matches PrcImporter pattern) --

  test "rows with blank/whitespace identifiers AND no npi are rejected" do
    csv = <<~CSV
      ccn,effective_date
      ,2015-01-01
      \t  ,2015-01-02
      451301,2015-01-03
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_equal "451301", result[:rows][0][:ccn]
    assert_equal 2, result[:rejects].size
    assert(result[:rejects].all? { |r| r[:reason].include?("at least one of ccn or npi") })
    assert_equal [ 2, 3 ], result[:rejects].map { |r| r[:row_number] }
  end

  test "row_number tracks original file line, accounting for comment lines" do
    csv = <<~CSV
      # release_label: cms_cah_2025q4
      # second comment
      ccn,effective_date
      451301,2015-01-01
      ,2015-02-01
      # a comment between data rows is also possible
      ,2015-03-01
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_equal [ 5, 7 ], result[:rejects].map { |r| r[:row_number] },
                 "row_numbers must reference original source lines so an ops " \
                 "engineer can locate the offending row directly in the file"
  end

  # -- Header normalization (BOM + casing) ------------------------------------

  test "header parsing tolerates UTF-8 BOM at the start of the file" do
    csv = "﻿ccn,effective_date\n451301,2015-01-01\n"
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_equal "451301", result[:rows][0][:ccn]
  end

  test "header matching is case-insensitive" do
    csv = <<~CSV
      CCN,Effective_Date,Facility_Name
      451301,2015-01-01,Test CAH
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_equal "451301", result[:rows][0][:ccn]
    assert_equal "Test CAH", result[:rows][0][:facility_name]
  end

  test "rows with missing or malformed effective_date are rejected, not silently nilled" do
    csv = <<~CSV
      ccn,effective_date,end_date
      451301,BADDATE,2024-01-01
      451302,,2024-01-01
      451303,2015-01-01,
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_equal "451303", result[:rows][0][:ccn]
    assert_equal 2, result[:rejects].size
    assert(result[:rejects].all? { |r| r[:reason].include?("effective_date") },
           "reject reason names the offending field for ops triage")
  end

  # -- dedup_last_wins: both unique-index dimensions ------------------------

  test "dedup_last_wins collapses (ccn, effective_date) duplicates last-wins" do
    rows = [
      { ccn: "451301", npi: nil, effective_date: Date.new(2025, 1, 1), facility_name: "Older" },
      { ccn: "451301", npi: nil, effective_date: Date.new(2025, 1, 1), facility_name: "Newer" }
    ]
    out = Corvid::CmsFacilityListParser.dedup_last_wins(rows)
    assert_equal 1, out.size
    assert_equal "Newer", out[0][:facility_name]
  end

  test "dedup_last_wins drops a prior row that conflicts on (npi, effective_date) even with different ccn" do
    rows = [
      { ccn: "451301", npi: "1234567890", effective_date: Date.new(2025, 1, 1), facility_name: "First" },
      { ccn: "451302", npi: "1234567890", effective_date: Date.new(2025, 1, 1), facility_name: "Second" }
    ]
    out = Corvid::CmsFacilityListParser.dedup_last_wins(rows)
    assert_equal 1, out.size, "shared NPI/date forces last-wins despite different CCNs; " \
                              "would otherwise crash the (npi, effective_date) partial unique index"
    assert_equal "Second", out[0][:facility_name]
  end

  test "dedup_last_wins keeps independent identifiers in different effective_dates" do
    rows = [
      { ccn: "451301", npi: nil, effective_date: Date.new(2015, 1, 1) },
      { ccn: "451301", npi: nil, effective_date: Date.new(2020, 1, 1) }
    ]
    out = Corvid::CmsFacilityListParser.dedup_last_wins(rows)
    assert_equal 2, out.size, "different effective_dates are distinct historical periods"
  end

  # -- replace_by_identifier_conflict: cross-release upsert ------------------

  test "replace_by_identifier_conflict overrides an existing row at the same (ccn, effective_date)" do
    Corvid::CahFacility.create!(
      ccn: "451301", facility_name: "Old name",
      effective_date: Date.new(2025, 1, 1),
      source_release: "release_a"
    )
    Corvid::CmsFacilityListParser.replace_by_identifier_conflict(
      model_class: Corvid::CahFacility,
      rows: [ {
        ccn: "451301", npi: nil, facility_name: "New name",
        effective_date: Date.new(2025, 1, 1), end_date: nil,
        source_release: "release_b"
      } ]
    )
    assert_equal 1, Corvid::CahFacility.where(ccn: "451301").count
    row = Corvid::CahFacility.find_by(ccn: "451301")
    assert_equal "New name", row.facility_name
    assert_equal "release_b", row.source_release,
                 "later import is canonical; source_release is provenance, not a partition key"
  end

  test "replace_by_identifier_conflict overrides on the NPI dimension even when CCN differs" do
    Corvid::CahFacility.create!(
      ccn: "451301", npi: "1234567890",
      effective_date: Date.new(2025, 1, 1),
      source_release: "release_a"
    )
    Corvid::CmsFacilityListParser.replace_by_identifier_conflict(
      model_class: Corvid::CahFacility,
      rows: [ {
        ccn: "451302", npi: "1234567890",
        facility_name: "Corrected CCN",
        effective_date: Date.new(2025, 1, 1), end_date: nil,
        source_release: "release_b"
      } ]
    )
    assert_equal 1, Corvid::CahFacility.count,
                 "same NPI/date with corrected CCN replaces the prior row"
    assert_equal "451302", Corvid::CahFacility.first.ccn
  end

  test "replace_by_identifier_conflict leaves non-conflicting rows alone" do
    Corvid::CahFacility.create!(
      ccn: "OTHER", effective_date: Date.new(2025, 1, 1),
      source_release: "release_a"
    )
    Corvid::CmsFacilityListParser.replace_by_identifier_conflict(
      model_class: Corvid::CahFacility,
      rows: [ {
        ccn: "451301", npi: nil, facility_name: nil,
        effective_date: Date.new(2025, 1, 1), end_date: nil,
        source_release: "release_b"
      } ]
    )
    assert_equal 2, Corvid::CahFacility.count,
                 "different identifiers at the same date coexist; only conflicts are replaced"
  end

  test "replace_by_identifier_conflict is a no-op when rows is empty" do
    Corvid::CahFacility.create!(
      ccn: "451301", effective_date: Date.new(2025, 1, 1),
      source_release: "release_a"
    )
    Corvid::CmsFacilityListParser.replace_by_identifier_conflict(
      model_class: Corvid::CahFacility, rows: []
    )
    assert_equal 1, Corvid::CahFacility.count,
                 "empty import must not wipe existing data"
  end

  test "malformed end_date does not reject the row (end_date is optional)" do
    csv = <<~CSV
      ccn,effective_date,end_date
      451301,2015-01-01,BADDATE
    CSV
    result = Corvid::CmsFacilityListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_nil result[:rows][0][:end_date],
               "optional fields silently degrade to nil; required fields trigger a reject"
    assert_empty result[:rejects]
  end
end
