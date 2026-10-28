# frozen_string_literal: true

require "test_helper"

# Gate round 3 (#372): stub crosswalk provenance threads through import,
# persistence, and council-facing exception rollups.
class Corvid::FacilityCbsaStubProvenanceTest < ActiveSupport::TestCase
  TENANT = "tnt_facility_cbsa_stub_prov"

  SYNTH_ZIP = "77001"
  SYNTH_CBSA = "77077"
  STUB_CROSSWALK_RELEASE = "stub_v1"
  REAL_OPPS_RELEASE = "cms_opps_cy2026_final_rule"
  LOW_WAGE_INDEX = BigDecimal("0.85")

  def setup
    Corvid::PrcProcedureDictionary.register(
      "OUTPATIENT_STUB_XW",
      hcpcs: "12345", apc: "5071",
      description: "Synthetic outpatient for stub crosswalk provenance"
    )
    Corvid::PrcFacilityDictionary.register(
      "STUBZIP",
      name: "Stub crosswalk site", city: "Test City", state: "TS",
      zip: SYNTH_ZIP, locality: "02"
    )
  end

  def teardown
    Corvid::PrcProcedureDictionary.reset!
    Corvid::PrcFacilityDictionary.reset!
  end

  test "reanalyze persists stub crosswalk release_label and summary rolls up stub_data_loaded" do
    with_tenant(TENANT) do
      seed_stub_crosswalk_opps_reanalyze!(obligation_id: "OBL-STUB-XW-OPPS")

      analysis = Corvid::PrcObligation.find_by!(obligation_id: "OBL-STUB-XW-OPPS").latest_analysis
      assert_equal "opps", analysis.payment_system
      assert_equal "stub", analysis.rate_source
      assert_equal "stub_estimate", analysis.recovery_confidence
      assert_equal STUB_CROSSWALK_RELEASE, analysis.rate_source_release,
                   "stub crosswalk release_label must win over real OPPS row label for provenance"

      summary = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT)
      assert_equal({ "stub_data_loaded" => 1 }, summary[:exceptions][:by_reason],
                   "persisted stub_v1 release must classify as stub_data_loaded, not stub_fallback")
    end
  end

  test "summary by_reason is stub_data_loaded when reanalyze leaves real OPPS label on stub crosswalk row" do
    with_tenant(TENANT) do
      seed_stub_crosswalk_opps_reanalyze!

      summary = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT)
      assert_equal({ "stub_data_loaded" => 1 }, summary[:exceptions][:by_reason],
                   "today returns stub_fallback because rate_source_release is the real OPPS label")
    end
  end

  def seed_stub_crosswalk_opps_reanalyze!(obligation_id: "OBL-STUB-XW-SUM")
    outpatient = <<~PRC
      H^PRC_EXPORT^STUBZIP^20260301^1
      O^#{obligation_id}^DFN001^VEND-HOSP^OUTPATIENT_STUB_XW^20260315^A^5000.00^3000.00^2000.00^0.00^2026
      T^1^1^0^3000.00^0.00
    PRC
    Corvid::PrcImporter.import(outpatient, source_file: "stub_xw_opps_sum.prc")
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA,
      release_label: STUB_CROSSWALK_RELEASE
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: SYNTH_CBSA,
      base_rate: 6_000.0, wage_index: LOW_WAGE_INDEX
    )
    Corvid::OppsApcWeight.create!(
      calendar_year: 2026, apc_code: "5071", relative_weight: 25.4378,
      release_label: REAL_OPPS_RELEASE
    )
    Corvid::OppsConversionFactor.create!(
      calendar_year: 2026, locality: "NATIONAL",
      conversion_factor: 89.169, wage_index: 1.0,
      release_label: REAL_OPPS_RELEASE
    )
    Corvid::OppsConversionFactor.create!(
      calendar_year: 2026, locality: SYNTH_CBSA,
      conversion_factor: 89.169, wage_index: LOW_WAGE_INDEX,
      release_label: REAL_OPPS_RELEASE
    )
    Corvid::PrcImporter.reanalyze(tenant: TENANT)
  end
end
