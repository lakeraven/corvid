# frozen_string_literal: true

require "test_helper"

class Corvid::CmsAscParserTest < ActiveSupport::TestCase
  # -- HCPCS rates -----------------------------------------------------------

  test "parse_hcpcs_rates returns rows with strict decimal weights" do
    csv = <<~CSV
      hcpcs_code,payment_indicator,payment_weight
      0101T,R2,2.4065
      0102T,G2,29.2047
    CSV
    rows = Corvid::CmsAscParser.parse_hcpcs_rates(csv, calendar_year: 2026, release_label: "test")
    assert_equal 2, rows.size
    assert_equal "0101T", rows[0][:hcpcs_code]
    assert_equal "R2", rows[0][:payment_indicator]
    assert_in_delta 2.4065, rows[0][:payment_weight].to_f, 0.0001
    assert_equal 2026, rows[0][:calendar_year]
    assert_equal "test", rows[0][:release_label]
  end

  test "parse_hcpcs_rates raises on non-numeric weight (would silently become 0.0 via to_f)" do
    csv = <<~CSV
      hcpcs_code,payment_indicator,payment_weight
      0101T,R2,abc
    CSV
    err = assert_raises(Corvid::CmsAscParser::MalformedFileError) do
      Corvid::CmsAscParser.parse_hcpcs_rates(csv, calendar_year: 2026)
    end
    assert_match(/payment_weight=\"abc\"/, err.message)
  end

  test "parse_hcpcs_rates raises on letter-O-as-zero corruption (\"12O.34\")" do
    csv = <<~CSV
      hcpcs_code,payment_indicator,payment_weight
      0101T,R2,12O.34
    CSV
    assert_raises(Corvid::CmsAscParser::MalformedFileError) do
      Corvid::CmsAscParser.parse_hcpcs_rates(csv, calendar_year: 2026)
    end
  end

  test "parse_hcpcs_rates strips BOM and comment lines" do
    csv = "\xEF\xBB\xBF" + <<~CSV
      # release_label: cms_asc_cy2026_final_rule
      hcpcs_code,payment_indicator,payment_weight
      0101T,R2,2.4065
    CSV
    rows = Corvid::CmsAscParser.parse_hcpcs_rates(csv, calendar_year: 2026)
    assert_equal 1, rows.size
  end

  test "parse_hcpcs_rates raises when required column missing" do
    csv = "hcpcs_code\n0101T\n"
    assert_raises(Corvid::CmsAscParser::MalformedFileError) do
      Corvid::CmsAscParser.parse_hcpcs_rates(csv, calendar_year: 2026)
    end
  end

  # -- Conversion factors ----------------------------------------------------

  test "parse_conversion_factors returns rows with strict decimal" do
    csv = <<~CSV
      locality,conversion_factor,wage_index
      NATIONAL,56.3220,1.0000
    CSV
    rows = Corvid::CmsAscParser.parse_conversion_factors(csv, calendar_year: 2026, release_label: "test")
    assert_equal 1, rows.size
    assert_in_delta 56.3220, rows[0][:conversion_factor].to_f, 0.0001
    assert_in_delta 1.0000, rows[0][:wage_index].to_f, 0.0001
  end

  test "parse_conversion_factors raises on non-numeric CF (silent 0.0 via to_f would zero-out every ASC rate)" do
    csv = <<~CSV
      locality,conversion_factor,wage_index
      NATIONAL,abc,1.0
    CSV
    err = assert_raises(Corvid::CmsAscParser::MalformedFileError) do
      Corvid::CmsAscParser.parse_conversion_factors(csv, calendar_year: 2026)
    end
    assert_match(/conversion_factor=\"abc\"/, err.message)
  end

  test "parse_conversion_factors raises on non-numeric wage_index" do
    csv = <<~CSV
      locality,conversion_factor,wage_index
      NATIONAL,56.322,xyz
    CSV
    assert_raises(Corvid::CmsAscParser::MalformedFileError) do
      Corvid::CmsAscParser.parse_conversion_factors(csv, calendar_year: 2026)
    end
  end
end
