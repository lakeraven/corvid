# frozen_string_literal: true

require "test_helper"

class Corvid::CmsPosAscNormalizerTest < ActiveSupport::TestCase
  FIXTURE = File.expand_path("../../fixtures/cms_pos_iqies_sample.csv", __dir__)

  test "normalize keeps only ASC rows (prvdr_type_id=11)" do
    result = Corvid::CmsPosAscNormalizer.normalize(FIXTURE)
    ccns = result[:rows].map { |r| r[:ccn] }.sort
    assert_equal [ "04C0001111", "07C0001069", "17C0001897" ], ccns,
                 "HHA (type 3) and dialysis (type 7) must be filtered out"
    assert_empty result[:rejects]
  end

  test "active ASC ('Not Available' sentinel) has nil end_date" do
    result = Corvid::CmsPosAscNormalizer.normalize(FIXTURE)
    active = result[:rows].find { |r| r[:ccn] == "17C0001897" }
    assert_nil active[:end_date]
    assert_equal "2018-04-12", active[:effective_date]
  end

  test "terminated ASC has end_date from trmntn_exprtn_dt" do
    result = Corvid::CmsPosAscNormalizer.normalize(FIXTURE)
    terminated = result[:rows].find { |r| r[:ccn] == "04C0001111" }
    assert_equal "2022-08-31", terminated[:end_date]
  end

  test "ASC with malformed trmntn_exprtn_dt is rejected" do
    bad = Tempfile.new([ "bad", ".csv" ])
    bad.write(<<~CSV)
      prvdr_num,fac_name,prvdr_sbtyp_id,prvdr_type_id,orgnl_prtcptn_dt,trmntn_exprtn_dt
      99C0099999,Bad Date ASC,Not Applicable,11,2018-01-01,GARBAGE
      99C0099998,Active ASC,Not Applicable,11,2018-01-01,Not Available
    CSV
    bad.close
    result = Corvid::CmsPosAscNormalizer.normalize(bad.path)
    assert_equal [ "99C0099998" ], result[:rows].map { |r| r[:ccn] }
    assert_equal 1, result[:rejects].size
    assert_match(/malformed trmntn_exprtn_dt/, result[:rejects][0][:reason])
  ensure
    bad&.unlink
  end

  test "render emits canonical CSV with release_label marker" do
    result = Corvid::CmsPosAscNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsPosAscNormalizer.render(result[:rows], release_label: "cms_iqies_2026q1")
    assert_match(/\A# release_label: cms_iqies_2026q1/, csv)
    assert_match(/^17C0001897,,Founders Surgery Center LLC,2018-04-12,$/, csv)
    assert_match(/^04C0001111,,Decommissioned ASC,2010-01-15,2022-08-31$/, csv)
  end

  test "rendered output round-trips through CmsFacilityListParser" do
    result = Corvid::CmsPosAscNormalizer.normalize(FIXTURE)
    csv = Corvid::CmsPosAscNormalizer.render(result[:rows], release_label: "test")
    parsed = Corvid::CmsFacilityListParser.parse(csv, release_label: "test")
    assert_equal 3, parsed[:rows].size
    assert_empty parsed[:rejects]
  end

  test "BOM-prefixed header parses correctly (rows aren't silently dropped)" do
    # If header validation strips BOM but row parsing reads fresh,
    # row["prvdr_num"] returns nil for every row and the output is
    # empty while appearing "successful." Guard against that.
    bom = Tempfile.new([ "bom", ".csv" ])
    bom.binmode
    bom.write("\xEF\xBB\xBF".b)
    bom.write(<<~CSV)
      prvdr_num,fac_name,prvdr_sbtyp_id,prvdr_type_id,orgnl_prtcptn_dt,trmntn_exprtn_dt
      17C0001897,Founders Surgery Center LLC,Not Applicable,11,2018-04-12,Not Available
    CSV
    bom.close
    result = Corvid::CmsPosAscNormalizer.normalize(bom.path)
    assert_equal 1, result[:rows].size,
                 "BOM-prefixed header must still produce a row; silent drop is the failure mode"
    assert_equal "17C0001897", result[:rows][0][:ccn]
    assert_empty result[:rejects]
  ensure
    bom&.unlink
  end

  test "ASC with missing or malformed orgnl_prtcptn_dt is rejected with row context" do
    bad = Tempfile.new([ "bad", ".csv" ])
    bad.write(<<~CSV)
      prvdr_num,fac_name,prvdr_sbtyp_id,prvdr_type_id,orgnl_prtcptn_dt,trmntn_exprtn_dt
      99C0099999,Missing Effective Date,Not Applicable,11,,Not Available
      99C0099998,Malformed Effective Date,Not Applicable,11,BADDATE,Not Available
      99C0099997,Active Good Row,Not Applicable,11,2018-01-01,Not Available
    CSV
    bad.close
    result = Corvid::CmsPosAscNormalizer.normalize(bad.path)
    assert_equal [ "99C0099997" ], result[:rows].map { |r| r[:ccn] },
                 "only the row with a parseable effective_date survives"
    assert_equal 2, result[:rejects].size
    assert(result[:rejects].all? { |r| r[:reason].include?("orgnl_prtcptn_dt") },
           "reject reason names the offending field for ops triage")
  ensure
    bad&.unlink
  end

  test "missing required column raises MalformedFileError" do
    bad = Tempfile.new([ "bad", ".csv" ])
    bad.write("foo,bar\n1,2\n")
    bad.close
    assert_raises(Corvid::CmsPosAscNormalizer::MalformedFileError) do
      Corvid::CmsPosAscNormalizer.normalize(bad.path)
    end
  ensure
    bad&.unlink
  end
end
