# frozen_string_literal: true

require "test_helper"

class Corvid::CmsPosCahNormalizerTest < ActiveSupport::TestCase
  FIXTURE = File.expand_path("../../fixtures/cms_pos_cah_sample.csv", __dir__)

  test "normalize keeps only Hospital category + CAH subtype rows" do
    rows = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    ccns = rows.map { |r| r[:ccn] }.sort
    assert_equal [ "011300", "011301", "011302" ], ccns,
                 "regular short-term hospitals (subtype 01) and nursing facilities " \
                 "(category 12) must be filtered out"
  end

  test "active CAH (termination code 00) has nil end_date" do
    rows = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    active = rows.find { |r| r[:ccn] == "011300" }
    assert_nil active[:end_date]
    assert_equal "2002-11-01", active[:effective_date],
                 "effective_date anchors to ORGNL_PRTCPTN_DT, not CRTFCTN_DT"
  end

  test "terminated CAH carries TRMNTN_EXPRTN_DT as end_date" do
    rows = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    terminated = rows.find { |r| r[:ccn] == "011301" }
    assert_equal "2008-03-31", terminated[:end_date]
  end

  test "npi is nil (POS file doesn't carry NPI)" do
    rows = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    rows.each { |r| assert_nil r[:npi] }
  end

  test "render emits the canonical CSV with release_label marker" do
    rows = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsPosCahNormalizer.render(rows, release_label: "cms_pos_2026q1")
    assert_match(/\A# release_label: cms_pos_2026q1/, csv)
    assert_match(/^ccn,npi,facility_name,effective_date,end_date$/, csv)
    assert_match(/^011300,,WASHINGTON COUNTY HOSPITAL,2002-11-01,$/, csv)
    assert_match(/^011301,,ATMORE COMMUNITY HOSPITAL,2005-07-01,2008-03-31$/, csv)
  end

  test "rendered output round-trips through CmsFacilityListParser" do
    rows = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsPosCahNormalizer.render(rows, release_label: "test")
    parsed = Corvid::CmsFacilityListParser.parse(csv, release_label: "test")
    assert_equal 3, parsed[:rows].size
    assert_empty parsed[:rejects]
  end

  test "missing required column raises MalformedFileError" do
    bad = Tempfile.new([ "bad", ".csv" ])
    bad.write("FOO,BAR\n1,2\n")
    bad.close
    assert_raises(Corvid::CmsPosCahNormalizer::MalformedFileError) do
      Corvid::CmsPosCahNormalizer.normalize(bad.path)
    end
  ensure
    bad&.unlink
  end
end
