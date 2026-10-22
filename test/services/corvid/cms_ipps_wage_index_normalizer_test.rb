# frozen_string_literal: true

require "test_helper"

class Corvid::CmsIppsWageIndexNormalizerTest < ActiveSupport::TestCase
  FIXTURE = File.expand_path("../../fixtures/cms_ipps_wage_index_sample.txt", __dir__)

  test "normalize reads the occupational-mix-adjusted wage index per CBSA/rural-state code" do
    rows = Corvid::CmsIppsWageIndexNormalizer.normalize(FIXTURE)
    by_locality = rows.index_by { |r| r[:locality] }

    assert_equal %w[01 13740 31084], rows.map { |r| r[:locality] }
    # "01" = rural Alabama rest-of-state wage area
    assert_in_delta 0.6391, by_locality["01"][:wage_index], 0.0001
    # "13740" = Billings, MT MSA
    assert_in_delta 0.8961, by_locality["13740"][:wage_index], 0.0001
    # "31084" = Los Angeles-Long Beach-Glendale, CA Metropolitan Division
    assert_in_delta 1.2463, by_locality["31084"][:wage_index], 0.0001
  end

  test "render outputs the canonical ipps_hospital_rates CSV shape with a NATIONAL fallback row" do
    rows = Corvid::CmsIppsWageIndexNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsIppsWageIndexNormalizer.render(rows, base_rate: 6752.61, release_label: "cms_fy2026_final_rule")

    assert_match(/\A# release_label: cms_fy2026_final_rule/, csv)
    assert_match(/^locality,base_rate,wage_index$/, csv)
    assert_match(/^NATIONAL,6752\.61,1\.0000$/, csv)
    assert_match(/^13740,6752\.61,0\.8961$/, csv)
  end

  test "render output round-trips through CmsIppsParser.parse_hospital_rates" do
    rows = Corvid::CmsIppsWageIndexNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsIppsWageIndexNormalizer.render(rows, base_rate: 6752.61, release_label: "test")
    body = csv.lines.reject { |l| l.lstrip.start_with?("#") }.join
    parsed = Corvid::CmsIppsParser.parse_hospital_rates(body, fiscal_year: 2026, release_label: "test")

    # 3 CBSA/rural rows + the NATIONAL fallback row
    assert_equal 4, parsed.size
    billings = parsed.find { |r| r[:locality] == "13740" }
    assert_in_delta 0.8961, billings[:wage_index].to_f, 0.0001
    assert_in_delta 6752.61, billings[:base_rate].to_f, 0.01
  end

  test "malformed wage index raises with locality and line context" do
    bogus = Tempfile.new([ "bogus", ".txt" ])
    File.open(bogus.path, "wb") do |f|
      f.write("CBSAGEO\tCBSAGEO occmix wage index\r\n")
      f.write("01\tabc\r\n")
    end
    err = assert_raises(Corvid::CmsIppsWageIndexNormalizer::MalformedFileError) do
      Corvid::CmsIppsWageIndexNormalizer.normalize(bogus.path)
    end
    assert_match(/locality 01/, err.message)
  ensure
    bogus&.unlink
  end

  test "missing required column raises MalformedFileError" do
    bogus = Tempfile.new([ "bogus", ".txt" ])
    File.open(bogus.path, "wb") { |f| f.write("foo\tbar\r\n1\t2\r\n") }
    assert_raises(Corvid::CmsIppsWageIndexNormalizer::MalformedFileError) do
      Corvid::CmsIppsWageIndexNormalizer.normalize(bogus.path)
    end
  ensure
    bogus&.unlink
  end

  test "rows with blank locality or wage index are skipped, not raised" do
    partial = Tempfile.new([ "partial", ".txt" ])
    File.open(partial.path, "wb") do |f|
      f.write("CBSAGEO\tCBSAGEO occmix wage index\r\n")
      f.write("01\t0.6391\r\n")
      f.write("\t0.9000\r\n") # blank locality
      f.write("02\t\r\n")     # blank wage index
    end
    rows = Corvid::CmsIppsWageIndexNormalizer.normalize(partial.path)
    assert_equal [ "01" ], rows.map { |r| r[:locality] }
  ensure
    partial&.unlink
  end

  # Money exactness (ADR 0004): the base rate is a dollar amount and
  # the wage index multiplies dollar amounts, so neither may pass
  # through Float on the way into the canonical CSV.

  test "normalize returns the wage index as an exact BigDecimal" do
    rows = Corvid::CmsIppsWageIndexNormalizer.normalize(FIXTURE)
    billings = rows.find { |r| r[:locality] == "13740" }

    assert_kind_of BigDecimal, billings[:wage_index]
    assert_equal BigDecimal("0.8961"), billings[:wage_index]
  end

  test "render writes a string base rate exactly, padded to cents" do
    rows = [ { locality: "13740", wage_index: BigDecimal("0.8961") } ]
    csv = Corvid::CmsIppsWageIndexNormalizer.render(rows, base_rate: "6500", release_label: "test")

    assert_match(/^NATIONAL,6500\.00,1\.0000$/, csv)
    assert_match(/^13740,6500\.00,0\.8961$/, csv)
  end

  test "render refuses a base rate with sub-cent precision instead of rounding it" do
    rows = [ { locality: "13740", wage_index: BigDecimal("0.8961") } ]

    assert_raises(ArgumentError) do
      Corvid::CmsIppsWageIndexNormalizer.render(rows, base_rate: "6752.615", release_label: "test")
    end
  end

  test "render refuses a non-numeric, zero or negative base rate" do
    rows = [ { locality: "13740", wage_index: BigDecimal("0.8961") } ]

    [ "abc", "", "0", "-6752.61" ].each do |bad|
      assert_raises(ArgumentError, "base_rate=#{bad.inspect} should be refused") do
        Corvid::CmsIppsWageIndexNormalizer.render(rows, base_rate: bad, release_label: "test")
      end
    end
  end

  test "a zero, negative or non-finite wage index raises instead of zeroing the rate" do
    [ "0", "-0.5", "Infinity", "NaN" ].each do |bad|
      file = Tempfile.new([ "bad_wi", ".txt" ])
      File.open(file.path, "wb") do |f|
        f.write("CBSAGEO\tCBSAGEO occmix wage index\r\n")
        f.write("01\t#{bad}\r\n")
      end
      assert_raises(Corvid::CmsIppsWageIndexNormalizer::MalformedFileError, "wage index #{bad.inspect} should be refused") do
        Corvid::CmsIppsWageIndexNormalizer.normalize(file.path)
      end
    ensure
      file&.unlink
    end
  end
end
