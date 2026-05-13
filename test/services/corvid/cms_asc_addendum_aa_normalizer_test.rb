# frozen_string_literal: true

require "test_helper"

class Corvid::CmsAscAddendumAaNormalizerTest < ActiveSupport::TestCase
  FIXTURE = File.expand_path("../../fixtures/cms_asc_addendum_aa_sample.csv", __dir__)

  test "normalize keeps HCPCS rows with a positive Payment Weight" do
    rows = Corvid::CmsAscAddendumAaNormalizer.normalize(FIXTURE)
    codes = rows.map { |r| r[:hcpcs_code] }.sort
    assert_equal [ "0101T", "0102T", "0200T" ], codes,
                 "rows with blank weight (N1) and '.' sentinel (D5) are skipped"
  end

  test "payment_weight is parsed as Float, payment_indicator captured" do
    rows = Corvid::CmsAscAddendumAaNormalizer.normalize(FIXTURE)
    r2 = rows.find { |r| r[:hcpcs_code] == "0101T" }
    assert_in_delta 2.4065, r2[:payment_weight], 0.0001
    assert_equal "R2", r2[:payment_indicator]
  end

  test "render emits canonical CSV with release_label marker" do
    rows = Corvid::CmsAscAddendumAaNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsAscAddendumAaNormalizer.render(rows, release_label: "cms_asc_cy2026_final_rule")
    assert_match(/\A# release_label: cms_asc_cy2026_final_rule/, csv)
    assert_match(/^hcpcs_code,payment_indicator,payment_weight$/, csv)
    assert_match(/^0101T,R2,2\.4065$/, csv)
  end

  test "column resolution tolerates year drift in header label" do
    drift = Tempfile.new([ "drift", ".csv" ])
    drift.write(<<~CSV)
      "Addendum AA",,,,,,
      "Copyright",,,,,,
      ,,,,,,
      HCPCS Code,,Short Descriptor,Subject to Multiple Procedure Discounting,April 2024 Payment Indicator,April 2024 Payment Weight,April 2024 Payment Rate
      5071,,Test,N,G2,15.5000,$900.00
    CSV
    drift.close
    rows = Corvid::CmsAscAddendumAaNormalizer.normalize(drift.path)
    assert_equal 1, rows.size
    assert_equal "G2", rows[0][:payment_indicator]
    assert_in_delta 15.5, rows[0][:payment_weight], 0.0001
  ensure
    drift&.unlink
  end

  test "malformed payment_weight raises with row context" do
    bogus = Tempfile.new([ "bogus", ".csv" ])
    bogus.write(<<~CSV)
      "Addendum AA",,,,,,
      "Copyright",,,,,,
      ,,,,,,
      HCPCS Code,,Short Descriptor,Subject to Multiple Procedure Discounting,January 2026 Payment Indicator,January 2026 Payment Weight,January 2026 Payment Rate
      0101T,,Esw muscskel,Y,R2,12O.34,$135.54
    CSV
    bogus.close
    err = assert_raises(Corvid::CmsAscAddendumAaNormalizer::MalformedFileError) do
      Corvid::CmsAscAddendumAaNormalizer.normalize(bogus.path)
    end
    assert_match(/12O\.34/, err.message)
    assert_match(/HCPCS 0101T/, err.message)
  ensure
    bogus&.unlink
  end

  test "missing HCPCS header row raises MalformedFileError" do
    bad = Tempfile.new([ "bad", ".csv" ])
    bad.write("foo,bar\n1,2\n")
    bad.close
    assert_raises(Corvid::CmsAscAddendumAaNormalizer::MalformedFileError) do
      Corvid::CmsAscAddendumAaNormalizer.normalize(bad.path)
    end
  ensure
    bad&.unlink
  end
end
