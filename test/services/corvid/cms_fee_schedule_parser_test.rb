# frozen_string_literal: true

require "test_helper"
require "tempfile"

class Corvid::CmsFeeScheduleParserTest < ActiveSupport::TestCase
  # -- GPCI: pre-2021 format (no State column) -------------------------------
  # CMS schema 2007–2020:
  # Carrier, Locality, Name, Work GPCI, PE GPCI, MP GPCI

  test "parse_gpcis handles pre-2021 GPCI format with locality at index 1" do
    csv = <<~CSV
      ADDENDUM E. 2020 GPCI BY STATE AND LOCALITY,,,,,
      MAC,Locality,Locality Name,2020 PW GPCI,2020 PE GPCI,2020 MP GPCI
      10112,00,ALABAMA,1.000,0.889,0.707
      02102,01,ALASKA**,1.500,1.118,0.661
    CSV

    with_tempfile(csv) do |path|
      result = Corvid::CmsFeeScheduleParser.parse_gpcis(path)

      assert_equal 2, result.size
      assert_equal({ work: 1.000, pe: 0.889, mp: 0.707 }, result["00"])
      assert_equal({ work: 1.500, pe: 1.118, mp: 0.661 }, result["01"])
    end
  end

  # -- GPCI: 2021+ format (State column added) -------------------------------
  # CMS schema 2021+:
  # Carrier, State, Locality, Name, Work GPCI, PE GPCI, MP GPCI

  test "parse_gpcis handles 2021+ GPCI format with locality at index 2" do
    csv = <<~CSV
      ADDENDUM E. CY 2021 GPCI,,,,,,
      ,,,,,,
      MAC,State,Locality,Name,2021 PW GPCI,2021 PE GPCI,2021 MP GPCI
      10112,AL,00,ALABAMA,1.000,0.888,0.921
      02102,AK,01,ALASKA*,1.500,1.118,0.614
      01112,CA,54,BAKERSFIELD,1.035,1.065,0.704
    CSV

    with_tempfile(csv) do |path|
      result = Corvid::CmsFeeScheduleParser.parse_gpcis(path)

      assert_equal 3, result.size,
                   "expected 3 localities from 2021+ format, got #{result.size}: #{result.keys}"
      assert_equal({ work: 1.000, pe: 0.888, mp: 0.921 }, result["00"])
      assert_equal({ work: 1.500, pe: 1.118, mp: 0.614 }, result["01"])
      assert_equal({ work: 1.035, pe: 1.065, mp: 0.704 }, result["54"])
    end
  end

  test "parse_gpcis returns empty hash when no data rows match" do
    csv = "Header only,no data,here\n"
    with_tempfile(csv) do |path|
      assert_empty Corvid::CmsFeeScheduleParser.parse_gpcis(path)
    end
  end

  # -- RVU file finding ------------------------------------------------------

  test "find_rvu_file finds 2-digit-year file (legacy 2007-2025)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PPRRVU25_JAN.csv"), "")
      assert_match(/PPRRVU25_JAN\.csv$/,
                   Corvid::CmsFeeScheduleParser.find_rvu_file(dir, 2025))
    end
  end

  test "find_rvu_file finds 4-digit-year file (2026+)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PPRRVU2026_Jan_nonQPP.csv"), "")
      assert_match(/PPRRVU2026_Jan_nonQPP\.csv$/,
                   Corvid::CmsFeeScheduleParser.find_rvu_file(dir, 2026))
    end
  end

  test "find_rvu_file prefers nonQPP over QPP when both exist" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PPRRVU2026_Jan_QPP.csv"), "")
      File.write(File.join(dir, "PPRRVU2026_Jan_nonQPP.csv"), "")
      result = Corvid::CmsFeeScheduleParser.find_rvu_file(dir, 2026)
      assert_match(/nonQPP/, result,
                   "should prefer base nonQPP file over QPP-adjusted")
    end
  end

  test "find_rvu_file prefers JAN release over later quarterlies when nonQPP absent" do
    Dir.mktmpdir do |dir|
      # Mid-year quarterly updates (B/C/D) and the original A release (JAN).
      # Pre-2026 there is no nonQPP variant; tie-break on JAN preference so
      # ingest does not depend on filesystem glob order.
      File.write(File.join(dir, "PPRRVU22_OCT.csv"), "")
      File.write(File.join(dir, "PPRRVU22_JUL.csv"), "")
      File.write(File.join(dir, "PPRRVU22_JAN.csv"), "")
      result = Corvid::CmsFeeScheduleParser.find_rvu_file(dir, 2022)
      assert_match(/JAN/, result,
                   "should prefer JAN release when no nonQPP variant exists")
    end
  end

  test "find_gpci_file requires a year-matching token (no silent fallback)" do
    Dir.mktmpdir do |dir|
      # File matches the substring "GPCI" but does not include the year.
      # Previously a catchall fallback would have picked this; now it must not.
      File.write(File.join(dir, "GPCI_archive.csv"), "")
      result = Corvid::CmsFeeScheduleParser.find_gpci_file(dir, 2021)
      assert_nil result,
                 "must not fall back to GPCI-ish file lacking the year token"
    end
  end

  test "find_gpci_file is deterministic when multiple year-matching files exist" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "GPCI2021_revised.csv"), "")
      File.write(File.join(dir, "GPCI2021.csv"), "")
      result = Corvid::CmsFeeScheduleParser.find_gpci_file(dir, 2021)
      # Sorted ascending — "GPCI2021.csv" < "GPCI2021_revised.csv" lexicographically.
      assert_match(/GPCI2021\.csv$/, result,
                   "should pick deterministically by sort order, not glob order")
    end
  end

  test "find_rvu_file returns nil when no file present" do
    Dir.mktmpdir do |dir|
      assert_nil Corvid::CmsFeeScheduleParser.find_rvu_file(dir, 2030)
    end
  end

  # -- GPCI file finding -----------------------------------------------------

  test "find_gpci_file matches 4-digit-year naming (2017+)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "GPCI2021.csv"), "")
      result = Corvid::CmsFeeScheduleParser.find_gpci_file(dir, 2021)
      assert_match(/GPCI2021\.csv$/, result)
    end
  end

  test "find_gpci_file matches 2-digit-year naming (legacy)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "GPCI09.csv"), "")
      result = Corvid::CmsFeeScheduleParser.find_gpci_file(dir, 2009)
      assert_match(/GPCI09\.csv$/, result)
    end
  end

  # -- Conversion factor -----------------------------------------------------

  test "conversion_factor returns published value for known year" do
    assert_equal 32.7400, Corvid::CmsFeeScheduleParser.conversion_factor(2026)
    assert_equal 37.8975, Corvid::CmsFeeScheduleParser.conversion_factor(2007)
  end

  test "conversion_factor falls back for unknown future year" do
    assert_equal 32.74, Corvid::CmsFeeScheduleParser.conversion_factor(2099)
  end

  # -- RVU parsing -----------------------------------------------------------

  test "parse_rvus yields rows with non-zero work or pe" do
    csv = <<~CSV
      Header pre-1
      ,,,,,,
      HCPCS,MOD,DESC,STATUS,PAYMENT,WORK RVU,PE RVU,IND,FAC PE,IND,MP RVU
      99213,,Office visit,A,,1.30,1.25,,0.55,,0.10
      A0021,,Skip me zero,I,,0.00,0.00,,0.00,,0.00
    CSV

    with_tempfile(csv) do |path|
      yielded = []
      Corvid::CmsFeeScheduleParser.parse_rvus(path) do |cpt, work, pe, mp|
        yielded << [cpt, work, pe, mp]
      end

      assert_equal 1, yielded.size, "expected only 99213 (A0021 has zero work + pe)"
      assert_equal "99213", yielded.first[0]
      assert_in_delta 1.30, yielded.first[1], 0.001
    end
  end

  private

  def with_tempfile(content)
    f = Tempfile.new(["cms_test", ".csv"])
    f.write(content)
    f.close
    yield f.path
  ensure
    f&.unlink
  end
end
