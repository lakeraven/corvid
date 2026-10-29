# frozen_string_literal: true

require "test_helper"
require "csv"
require "json"

# Issue #372: detail.csv and methodology.json must attribute CBSA wage-area pricing.
class Corvid::PrcOverpaymentReportWageAreaProvenanceTest < ActiveSupport::TestCase
  TENANT = "tnt_report_wage_area_prov"

  RURAL_ZIP = "88202"
  RURAL_CBSA = "12"
  NATL_ZIP = "88999"
  CROSSWALK_RELEASE = "cucumber_synthetic_report"
  SERVICE_DATE = Date.new(2026, 3, 1)
  OPPS_RELEASE = "cucumber_opps_2026"

  def setup
    Corvid::PrcProcedureDictionary.register(
      "OUTPATIENT_WAGE_REPORT", hcpcs: "12345", apc: "5071",
      description: "Synthetic outpatient for report wage-area columns"
    )
    Corvid::PrcFacilityDictionary.register(
      "RURA", name: "Rural synthetic", city: "Test", state: "TS",
      zip: RURAL_ZIP, locality: "99"
    )
    Corvid::PrcFacilityDictionary.register(
      "NATL", name: "National fallback", city: "Test", state: "TS",
      zip: NATL_ZIP, locality: "99"
    )
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: RURAL_ZIP, cbsa: RURAL_CBSA, release_label: CROSSWALK_RELEASE
    )
    Corvid::OppsApcWeight.create!(
      calendar_year: 2026, apc_code: "5071", relative_weight: 25.4378,
      release_label: OPPS_RELEASE
    )
    Corvid::OppsConversionFactor.create!(
      calendar_year: 2026, locality: "NATIONAL",
      conversion_factor: 70.0, wage_index: 1.0, release_label: OPPS_RELEASE
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: "NATIONAL", base_rate: 6_000.0, wage_index: 1.0,
      release_label: "cucumber_wage_2026"
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: RURAL_CBSA, base_rate: 6_000.0, wage_index: 0.85,
      release_label: "cucumber_wage_2026"
    )
  end

  def teardown
    Corvid::PrcProcedureDictionary.reset!
    Corvid::PrcFacilityDictionary.reset!
  end

  test "DETAIL_CSV_HEADERS appends wage_area and crosswalk_release after rate_source_release" do
    headers = Corvid::PrcOverpaymentReportService::DETAIL_CSV_HEADERS
    release_idx = headers.index("rate_source_release")
    refute_nil release_idx
    assert_equal "wage_area", headers[release_idx + 1]
    assert_equal "crosswalk_release", headers[release_idx + 2]
  end

  test "detail rows and detail.csv distinguish CBSA-adjusted from NATIONAL institutional pricing" do
    with_tenant(TENANT) do
      seed_two_facility_obligations!
      Corvid::PrcImporter.reanalyze(tenant: TENANT)

      rows = Corvid::PrcOverpaymentReportService.detail(tenant: TENANT)
      rural = rows.find { |r| r[:obligation_id] == "OBL-RURA-OPPS" }
      natl = rows.find { |r| r[:obligation_id] == "OBL-NATL-OPPS" }
      refute_nil rural
      refute_nil natl

      assert_in_delta 1513.55, rural[:medicare_equivalent].to_f, 0.01
      assert_in_delta 1780.65, natl[:medicare_equivalent].to_f, 0.01
      assert_equal RURAL_CBSA, rural[:wage_area]
      assert_equal CROSSWALK_RELEASE, rural[:crosswalk_release]
      assert_equal "NATIONAL", natl[:wage_area]
      assert_nil natl[:crosswalk_release]

      table = CSV.parse(
        Corvid::PrcOverpaymentReportService.to_csv_detail(tenant: TENANT),
        headers: true
      )
      assert_includes table.headers, "wage_area"
      assert_includes table.headers, "crosswalk_release"
      rural_csv = table.find { |r| r["obligation_id"] == "OBL-RURA-OPPS" }
      natl_csv = table.find { |r| r["obligation_id"] == "OBL-NATL-OPPS" }
      assert_equal RURAL_CBSA, rural_csv["wage_area"]
      assert_equal CROSSWALK_RELEASE, rural_csv["crosswalk_release"]
      assert_equal "NATIONAL", natl_csv["wage_area"]
      assert natl_csv["crosswalk_release"].nil? || natl_csv["crosswalk_release"].empty?
    end
  end

  test "audit packet methodology.json lists distinct crosswalk_release values from recoverable rows" do
    with_tenant(TENANT) do
      seed_two_facility_obligations!
      Corvid::PrcImporter.reanalyze(tenant: TENANT)

      packet = Corvid::PrcOverpaymentReportService.to_audit_packet(tenant: TENANT)
      meta = JSON.parse(packet["methodology.json"])

      assert_equal [ CROSSWALK_RELEASE ], meta["crosswalk_releases"],
                   "recoverable rural OPPS row must surface its crosswalk release; NATIONAL row contributes nil"
      assert_includes meta["rate_source_releases"], OPPS_RELEASE
    end
  end

  private

  def seed_two_facility_obligations!
    [ [ "RURA", "OBL-RURA-OPPS" ], [ "NATL", "OBL-NATL-OPPS" ] ].each do |facility, obligation_id|
      export = <<~PRC
        H^PRC_EXPORT^#{facility}^#{SERVICE_DATE.strftime("%Y%m%d")}^1
        O^#{obligation_id}^DFN001^VEND-HOSP^OUTPATIENT_WAGE_REPORT^#{SERVICE_DATE.strftime("%Y%m%d")}^A^5000.00^5000.00^0.00^0.00^2026
        T^1^1^0^5000.00^0.00
      PRC
      Corvid::PrcImporter.import(export, source_file: "#{facility.downcase}_opps.prc")
    end
  end
end
