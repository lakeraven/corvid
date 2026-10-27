# frozen_string_literal: true

require "test_helper"

class Corvid::CmsZipCbsaParserTest < ActiveSupport::TestCase
  VALID_CSV = <<~CSV
    # ZIP to CBSA crosswalk, FY 2026
    # release_label: synthetic_fixture
    zip,cbsa
    88101,98765
    88202,12
  CSV

  test "parse returns one hash per data row with fiscal_year and release_label stamped in" do
    rows = Corvid::CmsZipCbsaParser.parse(
      VALID_CSV, fiscal_year: 2026, release_label: "synthetic_fixture"
    )

    assert_equal 2, rows.size
    urban = rows.find { |r| r[:zip] == "88101" }
    assert_equal 2026, urban[:fiscal_year]
    assert_equal "98765", urban[:cbsa]
    assert_equal "synthetic_fixture", urban[:release_label]

    rural = rows.find { |r| r[:zip] == "88202" }
    assert_equal "12", rural[:cbsa]
  end

  test "parse tolerates an empty CSV (header only)" do
    rows = Corvid::CmsZipCbsaParser.parse("zip,cbsa\n", fiscal_year: 2026, release_label: "empty")
    assert_empty rows
  end

  test "parse raises ArgumentError on a missing header row" do
    assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse("zip\n88101\n", fiscal_year: 2026, release_label: "bad")
    end
  end

  test "parse raises ArgumentError on a malformed zip naming the line without echoing the value" do
    bad_zip = "12ABC"
    csv = "zip,cbsa\n#{bad_zip},98765\n"
    err = assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse(csv, fiscal_year: 2026, release_label: "bad")
    end
    assert_match(/line\s+2/i, err.message)
    refute_includes err.message, bad_zip
  end

  test "parse raises ArgumentError on a malformed cbsa naming the line without echoing the value" do
    bad_cbsa = "ABCDE"
    csv = "zip,cbsa\n88101,#{bad_cbsa}\n"
    err = assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse(csv, fiscal_year: 2026, release_label: "bad")
    end
    assert_match(/line\s+2/i, err.message)
    refute_includes err.message, bad_cbsa
  end

  test "parse raises ArgumentError on a duplicate zip naming the line without echoing the value" do
    csv = "zip,cbsa\n88101,98765\n88101,11111\n"
    err = assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse(csv, fiscal_year: 2026, release_label: "dup")
    end
    assert_match(/line\s+3/i, err.message)
    refute_includes err.message, "88101"
    refute_includes err.message, "11111"
  end

  test "parse skips comment lines like other CMS canonical CSV importers" do
    csv = <<~CSV
      # release_label: comment_test
      zip,cbsa
      88101,98765
    CSV
    rows = Corvid::CmsZipCbsaParser.parse(csv, fiscal_year: 2026, release_label: "comment_test")
    assert_equal 1, rows.size
  end
end
