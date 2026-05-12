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

  test "missing APC header row raises ArgumentError" do
    bogus = Tempfile.new([ "bogus", ".csv" ])
    bogus.write("foo,bar\n1,2\n")
    bogus.close
    assert_raises(ArgumentError) do
      Corvid::CmsOppsAddendumANormalizer.normalize(bogus.path)
    end
  ensure
    bogus&.unlink
  end
end
