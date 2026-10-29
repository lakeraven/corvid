# frozen_string_literal: true

require "test_helper"

# Issue #372 / PR #721: audit packet must attribute CBSA-adjusted dollars via
# structured wage_area and crosswalk_release on persisted analysis rows.
class Corvid::PrcOverpaymentAnalysisWageAreaPersistenceTest < ActiveSupport::TestCase
  TENANT = "tnt_wage_area_persist"

  SYNTH_ZIP = "77001"
  SYNTH_CBSA = "77077"
  NATL_ZIP = "88999"
  CROSSWALK_RELEASE = "cucumber_synthetic_persist"
  LOW_WAGE_INDEX = BigDecimal("0.85")
  TEST_LOCALITY = "02"

  def teardown
    Corvid::PrcProcedureDictionary.reset!
    Corvid::PrcFacilityDictionary.reset!
  end

  test "schema exposes wage_area and crosswalk_release without a facility ZIP column" do
    columns = Corvid::PrcOverpaymentAnalysis.column_names
    assert_includes columns, "wage_area",
                    "corvid_prc_overpayment_analyses must persist resolved wage area (ADR #372)"
    assert_includes columns, "crosswalk_release",
                    "corvid_prc_overpayment_analyses must persist crosswalk release_label"
    refute_includes columns, "facility_zip", "ADR 0003: never store facility ZIP on analyses"
    refute_includes columns, "zip"
  end

  test "reanalyze persists wage_area and crosswalk_release for CBSA-resolved IPPS claim" do
    register_ipps_facility!(code: "IPPS-CBSA", zip: SYNTH_ZIP)
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA, release_label: CROSSWALK_RELEASE
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2009, locality: "NATIONAL", base_rate: 6_000.0, wage_index: 1.0
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2009, locality: SYNTH_CBSA, base_rate: 6_000.0, wage_index: LOW_WAGE_INDEX
    )
    Corvid::IppsDrgWeight.create!(fiscal_year: 2009, drg_code: "470", relative_weight: 2.0743)

    with_tenant(TENANT) do
      import_and_reanalyze!(
        facility: "IPPS-CBSA", obligation_id: "OBL-IPPS-CBSA", procedure: "HIP_REPLACE_THR"
      )
      analysis = latest_analysis("OBL-IPPS-CBSA")
      assert_equal "ipps", analysis.payment_system
      assert_equal SYNTH_CBSA, analysis.wage_area
      assert_equal CROSSWALK_RELEASE, analysis.crosswalk_release
      assert_wage_provenance_columns_never_store_zip(analysis, facility_zip: SYNTH_ZIP)
    end
  end

  test "reanalyze persists NATIONAL wage_area and crosswalk_release when crosswalk CBSA has no wage-index row" do
    register_ipps_facility!(code: "IPPS-NOWL", zip: SYNTH_ZIP)
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA, release_label: CROSSWALK_RELEASE
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2009, locality: "NATIONAL", base_rate: 6_000.0, wage_index: 1.0
    )
    Corvid::IppsDrgWeight.create!(fiscal_year: 2009, drg_code: "470", relative_weight: 2.0743)

    with_tenant(TENANT) do
      import_and_reanalyze!(
        facility: "IPPS-NOWL", obligation_id: "OBL-IPPS-NOWL", procedure: "HIP_REPLACE_THR"
      )
      analysis = latest_analysis("OBL-IPPS-NOWL")
      assert_equal "ipps", analysis.payment_system
      assert_equal "NATIONAL", analysis.wage_area
      assert_equal CROSSWALK_RELEASE, analysis.crosswalk_release
      assert_in_delta expected_ipps_national_rate, analysis.medicare_equivalent.to_f, 0.01
      assert_wage_provenance_columns_never_store_zip(analysis, facility_zip: SYNTH_ZIP)
    end
  end

  test "reanalyze persists NATIONAL wage_area and nil crosswalk_release when institutional ZIP has no crosswalk row" do
    register_outpatient_procedure!
    register_ipps_facility!(code: "NATL-FAC", zip: NATL_ZIP)
    seed_opps_national(calendar_year: 2009)

    with_tenant(TENANT) do
      import_and_reanalyze!(
        facility: "NATL-FAC", obligation_id: "OBL-NATL-OPPS", procedure: "OUTPATIENT_PERSIST"
      )
      analysis = latest_analysis("OBL-NATL-OPPS")
      assert_equal "opps", analysis.payment_system
      assert_equal "NATIONAL", analysis.wage_area
      assert_nil analysis.crosswalk_release
      assert_wage_provenance_columns_never_store_zip(analysis, facility_zip: NATL_ZIP)
    end
  end

  test "reanalyze leaves wage_area and crosswalk_release nil for professional PFS claim" do
    register_ipps_facility!(code: "PFS-FAC", zip: SYNTH_ZIP, locality: TEST_LOCALITY)
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA, release_label: CROSSWALK_RELEASE
    )
    Corvid::FeeScheduleEntry.connection.execute("TRUNCATE corvid_fee_schedule_entries")
    Corvid::FeeScheduleEntry.create!(
      cpt_code: "99213", locality: TEST_LOCALITY, effective_date: Date.new(2009, 5, 4),
      work_rvu: 0.97, work_gpci: 1.0, pe_rvu: 0.85, pe_gpci: 1.0,
      mp_rvu: 0.07, mp_gpci: 1.0, conversion_factor: 36.0, release_label: "pfs_test"
    )

    with_tenant(TENANT) do
      import_and_reanalyze!(
        facility: "PFS-FAC", obligation_id: "OBL-PFS", procedure: "OFFICE_VISIT_EST"
      )
      analysis = latest_analysis("OBL-PFS")
      assert_equal "pfs", analysis.payment_system
      assert_nil analysis.wage_area
      assert_nil analysis.crosswalk_release
      assert_wage_provenance_columns_never_store_zip(analysis, facility_zip: SYNTH_ZIP)
    end
  ensure
    Corvid::FeeScheduleEntry.connection.execute("TRUNCATE corvid_fee_schedule_entries")
  end

  private

  def register_outpatient_procedure!
    Corvid::PrcProcedureDictionary.register(
      "OUTPATIENT_PERSIST", hcpcs: "12345", apc: "5071",
      description: "Synthetic outpatient for wage-area persistence"
    )
  end

  def register_ipps_facility!(code:, zip:, locality: TEST_LOCALITY)
    Corvid::PrcFacilityDictionary.register(
      code, name: "Synthetic site", city: "Test", state: "TS",
      zip: zip, locality: locality
    )
  end

  def seed_opps_national(calendar_year:)
    Corvid::OppsApcWeight.create!(
      calendar_year: calendar_year, apc_code: "5071", relative_weight: 25.4378,
      release_label: "cms_opps_cy2009_final_rule"
    )
    Corvid::OppsConversionFactor.create!(
      calendar_year: calendar_year, locality: "NATIONAL",
      conversion_factor: 70.0, wage_index: 1.0,
      release_label: "cms_opps_cy2009_final_rule"
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: calendar_year, locality: "NATIONAL", base_rate: 6_000.0, wage_index: 1.0
    )
  end

  def import_and_reanalyze!(facility:, obligation_id:, procedure:, service_date: Date.new(2009, 5, 4))
    export = <<~PRC
      H^PRC_EXPORT^#{facility}^#{service_date.strftime("%Y%m%d")}^1
      O^#{obligation_id}^DFN001^VEND-HOSP^#{procedure}^#{service_date.strftime("%Y%m%d")}^A^5000.00^3000.00^2000.00^0.00^2009
      T^1^1^0^3000.00^0.00
    PRC
    Corvid::PrcImporter.import(export, source_file: "wage_area_persist.prc")
    Corvid::PrcImporter.reanalyze(tenant: TENANT)
  end

  def latest_analysis(obligation_id)
    obligation = Corvid::PrcObligation.find_by!(obligation_id: obligation_id)
    Corvid::PrcOverpaymentAnalysis
      .where(prc_obligation: obligation)
      .order(analyzed_at: :desc, id: :desc)
      .first!
  end

  def assert_wage_provenance_columns_never_store_zip(analysis, facility_zip:)
    normalized = facility_zip.to_s[0, 5]
    [ analysis.wage_area, analysis.crosswalk_release ].each do |value|
      next if value.nil?

      refute_includes value.to_s, normalized,
                      "wage provenance columns must not echo facility ZIP (ADR 0003)"
    end
  end

  def expected_ipps_national_rate
    (BigDecimal("2.0743") * 6_000 * 1.0).round(2).to_f
  end
end
