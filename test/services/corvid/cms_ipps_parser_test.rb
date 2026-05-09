# frozen_string_literal: true

require "test_helper"

# CmsIppsParser parses the canonical CSV shape we normalize CMS Final
# Rule files into. Production data ingestion (downloading + normalizing
# the actual CMS XLSX files for FY 2009-2026) is a follow-up PR; this
# parser handles whatever the canonical fixture looks like.
class Corvid::CmsIppsParserTest < ActiveSupport::TestCase
  DRG_CSV = <<~CSV
    drg_code,relative_weight
    470,2.0743
    469,3.6841
    287,0.9217
    236,5.7384
  CSV

  HOSPITAL_CSV = <<~CSV
    locality,base_rate,wage_index
    NATIONAL,6500.00,1.0000
    01,6500.00,1.0853
    02,6500.00,0.9421
  CSV

  test "parse_drg_weights returns one entry per row with fiscal_year stamped in" do
    rows = Corvid::CmsIppsParser.parse_drg_weights(DRG_CSV, fiscal_year: 2026)

    assert_equal 4, rows.size
    hip = rows.find { |r| r[:drg_code] == "470" }
    assert_equal 2026, hip[:fiscal_year]
    assert_equal BigDecimal("2.0743"), hip[:relative_weight]
  end

  test "parse_hospital_rates returns one entry per locality with fiscal_year stamped in" do
    rows = Corvid::CmsIppsParser.parse_hospital_rates(HOSPITAL_CSV, fiscal_year: 2026)

    assert_equal 3, rows.size
    national = rows.find { |r| r[:locality] == "NATIONAL" }
    assert_equal 2026, national[:fiscal_year]
    assert_equal BigDecimal("6500.00"), national[:base_rate]
    assert_equal BigDecimal("1.0000"), national[:wage_index]
  end

  test "parse_drg_weights tolerates an empty CSV (header only)" do
    rows = Corvid::CmsIppsParser.parse_drg_weights("drg_code,relative_weight\n", fiscal_year: 2026)
    assert_empty rows
  end

  test "parse_drg_weights raises on missing required columns" do
    assert_raises(Corvid::CmsIppsParser::MalformedFileError) do
      Corvid::CmsIppsParser.parse_drg_weights("drg_code\n470\n", fiscal_year: 2026)
    end
  end

  test "parse_hospital_rates raises on missing required columns" do
    assert_raises(Corvid::CmsIppsParser::MalformedFileError) do
      Corvid::CmsIppsParser.parse_hospital_rates("locality,base_rate\n01,6500.00\n", fiscal_year: 2026)
    end
  end

  test "parse_drg_weights skips blank lines" do
    csv = "drg_code,relative_weight\n470,2.0743\n\n   \n469,3.6841\n"
    rows = Corvid::CmsIppsParser.parse_drg_weights(csv, fiscal_year: 2026)
    assert_equal [ "470", "469" ], rows.map { |r| r[:drg_code] }
  end

  test "parse_drg_weights tolerates a UTF-8 BOM on the header row" do
    bom = (+"\xEF\xBB\xBF").force_encoding("UTF-8")
    csv = "#{bom}drg_code,relative_weight\n470,2.0743\n"
    rows = Corvid::CmsIppsParser.parse_drg_weights(csv, fiscal_year: 2026)
    assert_equal 1, rows.size
    assert_equal "470", rows[0][:drg_code]
  end

  test "parse_hospital_rates tolerates thousands-separator commas and dollar prefixes" do
    csv = "locality,base_rate,wage_index\nNATIONAL,\"$6,500.00\",1.0000\n"
    rows = Corvid::CmsIppsParser.parse_hospital_rates(csv, fiscal_year: 2026)
    assert_equal BigDecimal("6500.00"), rows[0][:base_rate]
  end

  test "parse_drg_weights raises a clear MalformedFileError on un-parseable decimals" do
    csv = "drg_code,relative_weight\n470,not-a-number\n"
    err = assert_raises(Corvid::CmsIppsParser::MalformedFileError) do
      Corvid::CmsIppsParser.parse_drg_weights(csv, fiscal_year: 2026)
    end
    assert_match(/relative_weight/, err.message)
    assert_match(/470/, err.message, "error message names the offending row")
  end
end
