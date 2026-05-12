# frozen_string_literal: true

require "test_helper"

class Corvid::CmsCahListParserTest < ActiveSupport::TestCase
  test "parses required columns into row hashes" do
    csv = <<~CSV
      ccn,npi,facility_name,effective_date,end_date
      451301,1234567890,Test Critical Access Hospital,2015-01-01,
      451302,,Another CAH,2020-06-15,2023-12-31
    CSV
    rows = Corvid::CmsCahListParser.parse(csv, release_label: "cms_cah_2025q4")

    assert_equal 2, rows.size
    assert_equal "451301", rows[0][:ccn]
    assert_equal "1234567890", rows[0][:npi]
    assert_equal "Test Critical Access Hospital", rows[0][:facility_name]
    assert_equal Date.new(2015, 1, 1), rows[0][:effective_date]
    assert_nil rows[0][:end_date]
    assert_equal "cms_cah_2025q4", rows[0][:source_release]

    assert_nil rows[1][:npi], "blank npi normalizes to nil via .presence"
    assert_equal Date.new(2023, 12, 31), rows[1][:end_date]
  end

  test "skips comment lines so a release_label marker can ride on the file" do
    csv = <<~CSV
      # release_label: cms_cah_2025q4
      ccn,effective_date
      451301,2015-01-01
    CSV
    rows = Corvid::CmsCahListParser.parse(csv, release_label: "cms_cah_2025q4")
    assert_equal 1, rows.size
    assert_equal "451301", rows[0][:ccn]
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

  test "malformed date strings degrade to nil rather than exploding" do
    csv = <<~CSV
      ccn,effective_date,end_date
      451301,BADDATE,2024-99-99
    CSV
    rows = Corvid::CmsCahListParser.parse(csv, release_label: "x")
    assert_nil rows[0][:effective_date],
               "consistent with PrcReportParser's date-parse degradation pattern"
    assert_nil rows[0][:end_date]
  end
end
