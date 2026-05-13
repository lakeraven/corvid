# frozen_string_literal: true

require "test_helper"

class Corvid::CmsOppsAddendumANormalizerTest < ActiveSupport::TestCase
  FIXTURE = File.expand_path("../../fixtures/cms_opps_addendum_a_sample.csv", __dir__)

  test "normalize keeps APCs with a relative weight and a weighted status indicator" do
    rows = Corvid::CmsOppsAddendumANormalizer.normalize(FIXTURE)
    codes = rows.map { |r| r[:apc_code] }.sort
    assert_equal [ "2616", "5071", "5072" ], codes,
                 "drug pass-throughs (SI=G, no weight) and unweighted SI=N rows are skipped"
  end

  test "normalize parses the weight as a float, stripping commas" do
    rows = Corvid::CmsOppsAddendumANormalizer.normalize(FIXTURE)
    apc_5071 = rows.find { |r| r[:apc_code] == "5071" }
    assert_in_delta 25.4378, apc_5071[:relative_weight], 0.0001
    apc_2616 = rows.find { |r| r[:apc_code] == "2616" }
    assert_in_delta 194.3993, apc_2616[:relative_weight], 0.0001
  end

  test "render outputs the canonical CSV shape with a release_label marker" do
    rows = Corvid::CmsOppsAddendumANormalizer.normalize(FIXTURE)
    csv = Corvid::CmsOppsAddendumANormalizer.render(rows, release_label: "cms_opps_cy2026_final_rule")
    assert_match(/\A# release_label: cms_opps_cy2026_final_rule/, csv)
    assert_match(/^apc_code,relative_weight$/, csv)
    assert_match(/^5071,25\.4378$/, csv)
  end

  test "render output round-trips through CmsOppsParser" do
    rows = Corvid::CmsOppsAddendumANormalizer.normalize(FIXTURE)
    csv = Corvid::CmsOppsAddendumANormalizer.render(rows, release_label: "test")
    body = csv.lines.reject { |l| l.lstrip.start_with?("#") }.join
    parsed = Corvid::CmsOppsParser.parse_apc_weights(body, calendar_year: 2026, release_label: "test")
    assert_equal 3, parsed.size
    assert_equal "2616", parsed.first[:apc_code]
  end

  test "missing APC header row raises MalformedFileError" do
    bogus = Tempfile.new([ "bogus", ".csv" ])
    bogus.write("foo,bar\n1,2\n")
    bogus.close
    assert_raises(Corvid::CmsOppsAddendumANormalizer::MalformedFileError) do
      Corvid::CmsOppsAddendumANormalizer.normalize(bogus.path)
    end
  ensure
    bogus&.unlink
  end

  # -- Strict numeric parsing -------------------------------------------------
  # String#to_f silently converts "12O.34" to 12.0 (capital-O looks like
  # a zero) and "abc" to 0.0. Either failure mode would corrupt the
  # canonical APC weight file without raising — fail fast instead.

  test "malformed relative_weight raises with row context" do
    bogus = Tempfile.new([ "bogus", ".csv" ])
    bogus.write(<<~CSV)
      ,Addendum A,,,,,,,,
      ,Note,,,,,,,,
      APC,Group Title,SI,Relative Weight,Payment Rate
      5071,Level 1 Excision,J1,25.4378,$2324
      5072,Bad Weight,J1,12O.34,$3000
    CSV
    bogus.close
    err = assert_raises(Corvid::CmsOppsAddendumANormalizer::MalformedFileError) do
      Corvid::CmsOppsAddendumANormalizer.normalize(bogus.path)
    end
    assert_match(/12O\.34/, err.message)
    assert_match(/APC 5072/, err.message)
  ensure
    bogus&.unlink
  end

  test "non-numeric relative_weight raises (would have become 0.0 via to_f)" do
    bogus = Tempfile.new([ "bogus", ".csv" ])
    bogus.write(<<~CSV)
      ,Addendum A,,,,,,,,
      ,Note,,,,,,,,
      APC,Group Title,SI,Relative Weight,Payment Rate
      5071,Level 1,J1,abc,$2324
    CSV
    bogus.close
    assert_raises(Corvid::CmsOppsAddendumANormalizer::MalformedFileError) do
      Corvid::CmsOppsAddendumANormalizer.normalize(bogus.path)
    end
  ensure
    bogus&.unlink
  end

  # -- Header-name-based column resolution -----------------------------------
  # If CMS shifts column order in a quarterly variant, position-based
  # extraction would misread Relative Weight (e.g., picking up Payment
  # Rate by index). Resolve columns by label.

  test "reordered columns parse correctly via header-name lookup" do
    reordered = Tempfile.new([ "reord", ".csv" ])
    reordered.write(<<~CSV)
      ,Addendum A,,,,,,,,
      APC,SI,Relative Weight,Group Title,Payment Rate
      5071,J1,25.4378,Level 1 Excision,$2324
    CSV
    reordered.close
    rows = Corvid::CmsOppsAddendumANormalizer.normalize(reordered.path)
    assert_equal 1, rows.size
    assert_equal "5071", rows[0][:apc_code]
    assert_in_delta 25.4378, rows[0][:relative_weight], 0.0001
  ensure
    reordered&.unlink
  end

  test "header with extra internal whitespace still resolves (CY 2024 quirk)" do
    # CY 2024 quarterly Web Addendum A ships "Relative Weight" with a
    # double internal space and trailing/leading padding. Header match
    # must collapse whitespace runs, not just strip outer space.
    quirky = Tempfile.new([ "quirky", ".csv" ])
    quirky.write(<<~CSV)
      ,Addendum A,,,,,,,,
      APC ,Group Title,SI, Relative  Weight , Payment Rate
      5071,Level 1 Excision,J1,25.4378,$2324
    CSV
    quirky.close
    rows = Corvid::CmsOppsAddendumANormalizer.normalize(quirky.path)
    assert_equal 1, rows.size
    assert_in_delta 25.4378, rows[0][:relative_weight], 0.0001
  ensure
    quirky&.unlink
  end

  test "header missing a required column raises with the offending name" do
    missing_col = Tempfile.new([ "miss", ".csv" ])
    missing_col.write(<<~CSV)
      ,Addendum A,,,,,,,,
      APC,Group Title,Payment Rate
      5071,Level 1,$2324
    CSV
    missing_col.close
    err = assert_raises(Corvid::CmsOppsAddendumANormalizer::MalformedFileError) do
      Corvid::CmsOppsAddendumANormalizer.normalize(missing_col.path)
    end
    assert_match(/Relative Weight|SI/, err.message)
  ensure
    missing_col&.unlink
  end
end
