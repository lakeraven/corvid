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

  test "parse accepts a UTF-8 BOM before the header row" do
    csv = "\xEF\xBB\xBF#{VALID_CSV}"
    rows = Corvid::CmsZipCbsaParser.parse(csv, fiscal_year: 2026, release_label: "bom")
    assert_equal 2, rows.size
  end

  test "parse raises ArgumentError when the header is wrong but a valid data row follows" do
    assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse("foo,bar\n88101,12345\n", fiscal_year: 2026, release_label: "bad")
    end
  end

  test "parse raises ArgumentError when zip and cbsa columns are swapped in the header" do
    assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse("cbsa,zip\n12345,88101\n", fiscal_year: 2026, release_label: "swapped")
    end
  end

  test "parse preserves a zip with a leading zero" do
    rows = Corvid::CmsZipCbsaParser.parse(
      "zip,cbsa\n01234,98765\n", fiscal_year: 2026, release_label: "leading_zero"
    )
    assert_equal "01234", rows.first[:zip]
  end

  test "parse accepts ASCII-8BIT input that holds valid UTF-8 bytes" do
    binary = VALID_CSV.dup.force_encoding(Encoding::ASCII_8BIT)
    rows = Corvid::CmsZipCbsaParser.parse(binary, fiscal_year: 2026, release_label: "binary_utf8")
    assert_equal 2, rows.size
  end

  test "parse raises ArgumentError on invalid UTF-8 without echoing raw bytes" do
    invalid = "zip,cbsa\n".b + "\xC3\x28".b + ",98765\n".b
    err = assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse(invalid, fiscal_year: 2026, release_label: "bad_encoding")
    end
    assert(
      err.message.match?(/line\s+\d+/i) || err.message.match?(/encoding/i),
      "expected line number or encoding in message, got: #{err.message.inspect}"
    )
    refute_includes err.message, "\xC3"
    refute_includes err.message, "\x28"
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

  # Gate G1: no silent row loss from bare carriage returns (issue #371).
  MIXED_LINE_ENDINGS_CSV = "zip,cbsa\r\n01234,98765\n05555,12\r06666,13\r\n"

  test "parse raises ArgumentError instead of silently dropping a row with a bare carriage return" do
    assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse(
        MIXED_LINE_ENDINGS_CSV, fiscal_year: 2026, release_label: "cr_mixed"
      )
    end
  end

  test "parse returns all three zips when mixed line endings are normalized (no bare CR)" do
    rows = Corvid::CmsZipCbsaParser.parse(
      "zip,cbsa\n01234,98765\n05555,12\n06666,13\n",
      fiscal_year: 2026, release_label: "lf_only"
    )
    assert_equal %w[01234 05555 06666], rows.map { |r| r[:zip] }.sort
  end

  test "parse raises ArgumentError on header with bare carriage return naming the line without echoing values" do
    corrupt_token = "Q7CORRUPT"
    csv = "zip,cbsa\r#{corrupt_token}\n01234,98765\n"
    err = assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse(csv, fiscal_year: 2026, release_label: "cr_header")
    end
    assert_match(/line\s+1/i, err.message)
    assert_match(/header/i, err.message)
    refute_includes err.message, corrupt_token
  end

  test "parse raises malformed row on line number when a data line contains a bare carriage return" do
    csv = "zip,cbsa\n01234,98765\n05555,12\r06666,13\n"
    err = assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse(csv, fiscal_year: 2026, release_label: "cr_data")
    end
    assert_match(/malformed row on line 3/i, err.message)
    refute_includes err.message, "06666"
    refute_includes err.message, "05555"
  end

  test "parse raises ArgumentError on CR-only line separators instead of treating the file as empty" do
    assert_raises(ArgumentError) do
      Corvid::CmsZipCbsaParser.parse(
        "zip,cbsa\r01234,98765\r", fiscal_year: 2026, release_label: "cr_only"
      )
    end
  end

  test "parse accepts a normal CRLF file with multiple data rows" do
    rows = Corvid::CmsZipCbsaParser.parse(
      "zip,cbsa\r\n01234,98765\r\n05555,12\r\n",
      fiscal_year: 2026, release_label: "crlf"
    )
    assert_equal 2, rows.size
    assert_equal %w[01234 05555], rows.map { |r| r[:zip] }.sort
  end

  test "parse accepts quoted fields in a CRLF file" do
    rows = Corvid::CmsZipCbsaParser.parse(
      "zip,cbsa\r\n\"01234\",\"98765\"\r\n05555,12\r\n",
      fiscal_year: 2026, release_label: "quoted_crlf"
    )
    assert_equal 2, rows.size
    urban = rows.find { |r| r[:zip] == "01234" }
    assert_equal "98765", urban[:cbsa]
  end

  # Gate G2: anchored zip/cbsa formats (issue #371 mutant pins).
  {
    zip: %w[x01234y 012345],
    cbsa: %w[x12345y 123456]
  }.each do |field, values|
    values.each do |bad_value|
      test "parse raises ArgumentError on malformed #{field} #{bad_value.inspect} without echoing the value" do
        zip = field == :zip ? bad_value : "88101"
        cbsa = field == :cbsa ? bad_value : "98765"
        csv = "zip,cbsa\n#{zip},#{cbsa}\n"
        err = assert_raises(ArgumentError) do
          Corvid::CmsZipCbsaParser.parse(csv, fiscal_year: 2026, release_label: "bad_#{field}")
        end
        assert_match(/malformed #{field} on line 2/i, err.message)
        refute_includes err.message, bad_value
      end
    end
  end
end
