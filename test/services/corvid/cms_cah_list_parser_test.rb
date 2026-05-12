# frozen_string_literal: true

require "test_helper"

class Corvid::CmsCahListParserTest < ActiveSupport::TestCase
  test "parses required columns into row hashes" do
    csv = <<~CSV
      ccn,npi,facility_name,effective_date,end_date
      451301,1234567890,Test Critical Access Hospital,2015-01-01,
      451302,,Another CAH,2020-06-15,2023-12-31
    CSV
    result = Corvid::CmsCahListParser.parse(csv, release_label: "cms_cah_2025q4")

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
    result = Corvid::CmsCahListParser.parse(csv, release_label: "cms_cah_2025q4")
    assert_equal 1, result[:rows].size
    assert_equal "451301", result[:rows][0][:ccn]
  end

  test "raises ArgumentError when required columns are missing" do
    csv = <<~CSV
      facility_name,effective_date
      Test CAH,2015-01-01
    CSV
    assert_raises(ArgumentError) do
      Corvid::CmsCahListParser.parse(csv, release_label: "x")
    end
  end

  # -- Per-row rejects (permissive-but-report, matches PrcImporter pattern) --

  test "rows with blank or whitespace ccn are rejected" do
    csv = <<~CSV
      ccn,effective_date
      ,2015-01-01
      \t  ,2015-01-02
      451301,2015-01-03
    CSV
    result = Corvid::CmsCahListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_equal "451301", result[:rows][0][:ccn]
    assert_equal 2, result[:rejects].size
    assert(result[:rejects].all? { |r| r[:reason].include?("blank ccn") })
    assert_equal [ 2, 3 ], result[:rejects].map { |r| r[:row_number] }
  end

  test "rows with missing or malformed effective_date are rejected, not silently nilled" do
    csv = <<~CSV
      ccn,effective_date,end_date
      451301,BADDATE,2024-01-01
      451302,,2024-01-01
      451303,2015-01-01,
    CSV
    result = Corvid::CmsCahListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_equal "451303", result[:rows][0][:ccn]
    assert_equal 2, result[:rejects].size
    assert(result[:rejects].all? { |r| r[:reason].include?("effective_date") },
           "reject reason names the offending field for ops triage")
  end

  test "malformed end_date does not reject the row (end_date is optional)" do
    csv = <<~CSV
      ccn,effective_date,end_date
      451301,2015-01-01,BADDATE
    CSV
    result = Corvid::CmsCahListParser.parse(csv, release_label: "x")
    assert_equal 1, result[:rows].size
    assert_nil result[:rows][0][:end_date],
               "optional fields silently degrade to nil; required fields trigger a reject"
    assert_empty result[:rejects]
  end
end
