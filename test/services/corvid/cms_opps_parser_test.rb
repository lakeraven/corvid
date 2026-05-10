# frozen_string_literal: true

require "test_helper"

class Corvid::CmsOppsParserTest < ActiveSupport::TestCase
  APC_CSV = <<~CSV
    apc_code,relative_weight,description
    5071,25.4378,"Level 1 Excision/ Biopsy/ Incision and Drainage"
    5072,46.0916,"Level 2 Excision/ Biopsy/ Incision and Drainage"
  CSV

  CF_CSV = <<~CSV
    locality,conversion_factor,wage_index
    NATIONAL,89.169,1.0000
    01,89.169,1.0853
  CSV

  test "parse_apc_weights returns one entry per row with calendar_year stamped in" do
    rows = Corvid::CmsOppsParser.parse_apc_weights(APC_CSV, calendar_year: 2026)
    assert_equal 2, rows.size
    row = rows.find { |r| r[:apc_code] == "5071" }
    assert_equal 2026, row[:calendar_year]
    assert_equal BigDecimal("25.4378"), row[:relative_weight]
  end

  test "parse_conversion_factors returns one entry per locality" do
    rows = Corvid::CmsOppsParser.parse_conversion_factors(CF_CSV, calendar_year: 2026)
    assert_equal 2, rows.size
    national = rows.find { |r| r[:locality] == "NATIONAL" }
    assert_equal BigDecimal("89.169"), national[:conversion_factor]
    assert_equal BigDecimal("1.0000"), national[:wage_index]
  end

  test "release_label flows through to parsed rows" do
    rows = Corvid::CmsOppsParser.parse_apc_weights(APC_CSV, calendar_year: 2026, release_label: "cms_cy2026_final_rule")
    assert_equal "cms_cy2026_final_rule", rows.first[:release_label]
  end

  test "parse_apc_weights raises on missing required columns" do
    assert_raises(Corvid::CmsOppsParser::MalformedFileError) do
      Corvid::CmsOppsParser.parse_apc_weights("apc_code\n5071\n", calendar_year: 2026)
    end
  end

  test "parse_conversion_factors raises on missing required columns" do
    assert_raises(Corvid::CmsOppsParser::MalformedFileError) do
      Corvid::CmsOppsParser.parse_conversion_factors("locality,conversion_factor\nNATIONAL,89.169\n", calendar_year: 2026)
    end
  end
end
