# frozen_string_literal: true

require "test_helper"

class Corvid::CmsPosCahNormalizerTest < ActiveSupport::TestCase
  FIXTURE = File.expand_path("../../fixtures/cms_pos_cah_sample.csv", __dir__)

  test "normalize keeps only Hospital category + CAH subtype rows" do
    result = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    ccns = result[:rows].map { |r| r[:ccn] }.sort
    assert_equal [ "011300", "011301", "011302" ], ccns,
                 "regular short-term hospitals (subtype 01) and nursing facilities " \
                 "(category 12) must be filtered out"
    assert_empty result[:rejects]
  end

  test "active CAH (termination code 00) has nil end_date" do
    result = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    active = result[:rows].find { |r| r[:ccn] == "011300" }
    assert_nil active[:end_date]
    assert_equal "2002-11-01", active[:effective_date],
                 "effective_date anchors to ORGNL_PRTCPTN_DT, not CRTFCTN_DT"
  end

  test "terminated CAH carries TRMNTN_EXPRTN_DT as end_date" do
    result = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    terminated = result[:rows].find { |r| r[:ccn] == "011301" }
    assert_equal "2008-03-31", terminated[:end_date]
  end

  test "terminated CAH with missing TRMNTN_EXPRTN_DT is rejected, not emitted as nil-end_date" do
    # Critical safety check: a terminated row emitted with end_date=nil
    # would match CahFacility#applies? as open-ended and silently grant
    # the 1.01× multiplier to a terminated facility. Must reject instead.
    bad = Tempfile.new([ "bad", ".csv" ])
    bad.write(<<~CSV)
      PRVDR_CTGRY_SBTYP_CD,PRVDR_CTGRY_CD,FAC_NAME,PRVDR_NUM,ORGNL_PRTCPTN_DT,CRTFCTN_DT,PGM_TRMNTN_CD,TRMNTN_EXPRTN_DT
      11,01,Terminated With Missing Date,011999,20100101,20100101,01,
      11,01,Terminated With Malformed Date,012000,20100101,20100101,01,BADDATE
      11,01,Active CAH,012001,20100101,20100101,00,
    CSV
    bad.close
    result = Corvid::CmsPosCahNormalizer.normalize(bad.path)
    ccns_in_rows = result[:rows].map { |r| r[:ccn] }
    assert_equal [ "012001" ], ccns_in_rows,
                 "only the active CAH survives; terminated-with-no-date rejected"
    assert_equal 2, result[:rejects].size
    assert(result[:rejects].all? { |r| r[:reason].include?("terminated") },
           "reject reason names the failure mode for ops triage")
  ensure
    bad&.unlink
  end

  test "npi is nil (POS file doesn't carry NPI)" do
    result = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    result[:rows].each { |r| assert_nil r[:npi] }
  end

  test "render emits the canonical CSV with release_label marker" do
    result = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsPosCahNormalizer.render(result[:rows], release_label: "cms_pos_2026q1")
    assert_match(/\A# release_label: cms_pos_2026q1/, csv)
    assert_match(/^ccn,npi,facility_name,effective_date,end_date$/, csv)
    assert_match(/^011300,,WASHINGTON COUNTY HOSPITAL,2002-11-01,$/, csv)
    assert_match(/^011301,,ATMORE COMMUNITY HOSPITAL,2005-07-01,2008-03-31$/, csv)
  end

  test "rendered output round-trips through CmsFacilityListParser" do
    result = Corvid::CmsPosCahNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsPosCahNormalizer.render(result[:rows], release_label: "test")
    parsed = Corvid::CmsFacilityListParser.parse(csv, release_label: "test")
    assert_equal 3, parsed[:rows].size
    assert_empty parsed[:rejects]
  end

  # -- Header validation edge cases -----------------------------------------

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

  test "header validation tolerates UTF-8 BOM at start of file" do
    bom = Tempfile.new([ "bom", ".csv" ])
    bom.binmode
    bom.write("\xEF\xBB\xBF".b)
    bom.write(<<~CSV)
      PRVDR_CTGRY_SBTYP_CD,PRVDR_CTGRY_CD,FAC_NAME,PRVDR_NUM,ORGNL_PRTCPTN_DT,CRTFCTN_DT,PGM_TRMNTN_CD,TRMNTN_EXPRTN_DT
      11,01,BOM Sample,011500,20100101,20100101,00,
    CSV
    bom.close
    result = Corvid::CmsPosCahNormalizer.normalize(bom.path)
    assert_equal 1, result[:rows].size
    assert_equal "011500", result[:rows][0][:ccn]
  ensure
    bom&.unlink
  end

  test "header validation tolerates quoted headers" do
    quoted = Tempfile.new([ "q", ".csv" ])
    quoted.write(<<~CSV)
      "PRVDR_CTGRY_SBTYP_CD","PRVDR_CTGRY_CD","FAC_NAME","PRVDR_NUM","ORGNL_PRTCPTN_DT","CRTFCTN_DT","PGM_TRMNTN_CD","TRMNTN_EXPRTN_DT"
      11,01,Quoted Headers,011501,20100101,20100101,00,
    CSV
    quoted.close
    result = Corvid::CmsPosCahNormalizer.normalize(quoted.path)
    assert_equal 1, result[:rows].size
  ensure
    quoted&.unlink
  end
end
