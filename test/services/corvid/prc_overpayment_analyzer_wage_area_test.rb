# frozen_string_literal: true

require "test_helper"

# Binding pins for facility CBSA wage-area resolution (#372): single lookup
# per obligation, documented Result#wage_area / notes, zip normalization gate.
class Corvid::PrcOverpaymentAnalyzerWageAreaTest < ActiveSupport::TestCase
  TEST_LOCALITY = "02"
  TEST_DATE = Date.new(2009, 5, 4)

  SYNTH_ZIP = "77001"
  SYNTH_CBSA = "77077"
  LOW_WAGE_INDEX = BigDecimal("0.85")

  NATIONAL_WAGE_NOTE =
    "Wage area: NATIONAL (no crosswalk row for the facility ZIP)."

  def setup
    Corvid::FeeScheduleEntry.connection.execute("TRUNCATE corvid_fee_schedule_entries")
    seed_pfs_rate(cpt: "27130", rate_components: hip_27130_inputs)
    seed_pfs_rate(cpt: "99213", rate_components: office_99213_inputs)
  end

  def teardown
    Corvid::FeeScheduleEntry.connection.execute("TRUNCATE corvid_fee_schedule_entries")
    Corvid::PrcProcedureDictionary.reset!
    Corvid::PrcFacilityDictionary.reset!
  end

  # -- K1: one crosswalk query per obligation --------------------------------

  test "ASC miss OPPS miss stub fallback issues one zip crosswalk query per obligation" do
    register_outpatient_procedure!
    register_facility_for_cbsa(code: "ONCE", zip: SYNTH_ZIP)
    Corvid::ZipCbsaCrosswalk.create!(fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA)
    Corvid::AscFacility.create!(ccn: "ASC-VENDOR-1", effective_date: Date.new(2009, 1, 1))

    queries = count_zip_cbsa_crosswalk_queries do
      result = analyze_with_facility(
        facility_code: "ONCE", procedure: "OUTPATIENT_TEST", paid: 5_000,
        vendor_id: "ASC-VENDOR-1"
      ).results.first
      assert_equal :opps, result.payment_system
      assert_equal :stub_estimate, result.recovery_confidence
    end

    assert_equal 1, queries,
                 "wage area must be resolved once and reused for ASC, OPPS, and stub lookups"
  end

  test "IPPS stub fallback issues one zip crosswalk query per obligation" do
    register_facility_for_cbsa(code: "ONCE", zip: SYNTH_ZIP)
    Corvid::ZipCbsaCrosswalk.create!(fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA)

    queries = count_zip_cbsa_crosswalk_queries do
      result = analyze_with_facility(
        facility_code: "ONCE", procedure: "HIP_REPLACE_THR", paid: 42_000
      ).results.first
      assert_equal :ipps, result.payment_system
      assert_equal :stub_estimate, result.recovery_confidence
    end

    assert_equal 1, queries,
                 "wage area must be resolved once and reused for IPPS lookup and stub fallback"
  end

  # -- K2: wage_area attribute and notes -------------------------------------

  test "IPPS result records resolved wage area on Result and in notes" do
    register_facility_for_cbsa(code: "CBSA", zip: SYNTH_ZIP)
    seed_cbsa_crosswalk_and_wage_area(fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA)
    Corvid::IppsDrgWeight.create!(fiscal_year: 2009, drg_code: "470", relative_weight: 2.0743)

    result = analyze_with_facility(
      facility_code: "CBSA", procedure: "HIP_REPLACE_THR", paid: 42_000
    ).results.first

    assert_equal :ipps, result.payment_system
    assert_institutional_wage_area_documentation(
      result, facility_zip: SYNTH_ZIP, wage_area: SYNTH_CBSA
    )
  end

  test "OPPS result records resolved wage area on Result and in notes" do
    register_outpatient_procedure!
    register_facility_for_cbsa(code: "CBSA", zip: SYNTH_ZIP)
    seed_cbsa_crosswalk_and_wage_area(fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA)
    seed_opps_national_rows(calendar_year: 2009)

    result = analyze_with_facility(
      facility_code: "CBSA", procedure: "OUTPATIENT_TEST", paid: 5_000
    ).results.first

    assert_equal :opps, result.payment_system
    assert_institutional_wage_area_documentation(
      result, facility_zip: SYNTH_ZIP, wage_area: SYNTH_CBSA
    )
  end

  test "ASC result records resolved wage area on Result and in notes" do
    register_outpatient_procedure!
    register_facility_for_cbsa(code: "CBSA", zip: SYNTH_ZIP)
    seed_cbsa_crosswalk_and_wage_area(fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA)
    seed_asc_national_rows(calendar_year: 2009)
    Corvid::AscFacility.create!(ccn: "ASC-VENDOR-1", effective_date: Date.new(2009, 1, 1))

    result = analyze_with_facility(
      facility_code: "CBSA", procedure: "OUTPATIENT_TEST", paid: 1_000, vendor_id: "ASC-VENDOR-1"
    ).results.first

    assert_equal :asc, result.payment_system
    assert_institutional_wage_area_documentation(
      result, facility_zip: SYNTH_ZIP, wage_area: SYNTH_CBSA
    )
  end

  test "OPPS stub result records NATIONAL wage area on Result and in notes" do
    register_outpatient_procedure!
    register_facility_for_cbsa(code: "NATL", zip: "88999")

    result = analyze_with_facility(
      facility_code: "NATL", procedure: "OUTPATIENT_TEST", paid: 5_000
    ).results.first

    assert_equal :opps, result.payment_system
    assert_equal :stub_estimate, result.recovery_confidence
    assert_institutional_wage_area_documentation(
      result, facility_zip: "88999", wage_area: nil, national: true
    )
  end

  test "professional PFS result leaves wage_area nil and omits wage-area notes" do
    register_facility_for_cbsa(code: "CBSA", zip: SYNTH_ZIP, locality: TEST_LOCALITY)
    Corvid::ZipCbsaCrosswalk.create!(fiscal_year: 2009, zip: SYNTH_ZIP, cbsa: SYNTH_CBSA)

    result = analyze_with_facility(
      facility_code: "CBSA", procedure: "OFFICE_VISIT_EST", paid: 250
    ).results.first

    assert_equal :pfs, result.payment_system
    assert_nil result.wage_area
    refute_match(/Wage area:/, result.notes.to_s)
    refute_includes result.notes.to_s, SYNTH_ZIP
  end

  # -- K3: zip types price at NATIONAL without raising -----------------------

  test "institutional pricing with integer facility zip stays NATIONAL without raising" do
    register_outpatient_procedure!
    Corvid::ZipCbsaCrosswalk.create!(fiscal_year: 2009, zip: "88202", cbsa: "12")
    Corvid::PrcFacilityDictionary.register(
      "INTZIP", name: "Integer ZIP site", city: "Test", state: "TS",
      zip: 88_202, locality: TEST_LOCALITY
    )
    seed_opps_national_rows(calendar_year: 2009)

    result = nil
    assert_nothing_raised do
      result = analyze_with_facility(
        facility_code: "INTZIP", procedure: "OUTPATIENT_TEST", paid: 5_000
      ).results.first
    end

    assert_in_delta expected_opps_national_rate, result.medicare_equivalent.to_f, 0.01
    assert_institutional_wage_area_documentation(
      result, facility_zip: "88202", wage_area: nil, national: true
    )
  end

  test "institutional pricing with nil facility zip stays NATIONAL without raising" do
    register_outpatient_procedure!
    Corvid::PrcFacilityDictionary.register(
      "NOZIP", name: "No ZIP site", city: "Test", state: "TS",
      zip: nil, locality: TEST_LOCALITY
    )
    seed_opps_national_rows(calendar_year: 2009)

    result = nil
    assert_nothing_raised do
      result = analyze_with_facility(
        facility_code: "NOZIP", procedure: "OUTPATIENT_TEST", paid: 5_000
      ).results.first
    end

    assert_in_delta expected_opps_national_rate, result.medicare_equivalent.to_f, 0.01
    assert_institutional_wage_area_documentation(
      result, facility_zip: nil, wage_area: nil, national: true
    )
  end

  test "institutional pricing with trailing-hyphen zip stays NATIONAL without raising" do
    register_outpatient_procedure!
    Corvid::ZipCbsaCrosswalk.create!(fiscal_year: 2009, zip: "88202", cbsa: "12")
    Corvid::PrcFacilityDictionary.register(
      "HYPHZIP", name: "Hyphen ZIP site", city: "Test", state: "TS",
      zip: "88202-", locality: TEST_LOCALITY
    )
    seed_opps_national_rows(calendar_year: 2009)

    result = nil
    assert_nothing_raised do
      result = analyze_with_facility(
        facility_code: "HYPHZIP", procedure: "OUTPATIENT_TEST", paid: 5_000
      ).results.first
    end

    assert_in_delta expected_opps_national_rate, result.medicare_equivalent.to_f, 0.01
    assert_institutional_wage_area_documentation(
      result, facility_zip: "88202-", wage_area: nil, national: true
    )
  end

  private

  def count_zip_cbsa_crosswalk_queries
    count = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      count += 1 if sql&.include?("corvid_zip_cbsa_crosswalks")
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    count
  end

  def assert_institutional_wage_area_documentation(result, facility_zip:, wage_area:, national: false)
    if national
      assert_nil result.wage_area
      assert result.notes.end_with?(NATIONAL_WAGE_NOTE), "expected national wage-area note; got: #{result.notes}"
    else
      assert_equal wage_area, result.wage_area
      assert result.notes.end_with?("Wage area: #{wage_area}."),
             "expected resolved wage-area note; got: #{result.notes}"
    end

    zip_fragment = facility_zip.to_s
    refute_includes result.notes.to_s, zip_fragment unless zip_fragment.empty?
  end

  def register_facility_for_cbsa(code:, zip:, locality: TEST_LOCALITY)
    Corvid::PrcFacilityDictionary.register(
      code,
      name: "Synthetic site", city: "Test City", state: "TS",
      zip: zip, locality: locality
    )
  end

  def register_outpatient_procedure!
    Corvid::PrcProcedureDictionary.register(
      "OUTPATIENT_TEST", hcpcs: "12345", apc: "5071",
      description: "Test outpatient procedure"
    )
  end

  def seed_cbsa_crosswalk_and_wage_area(fiscal_year:, zip:, cbsa:, wage_index: LOW_WAGE_INDEX)
    Corvid::ZipCbsaCrosswalk.create!(fiscal_year: fiscal_year, zip: zip, cbsa: cbsa)
    Corvid::IppsHospitalRate.create!(
      fiscal_year: fiscal_year, locality: "NATIONAL", base_rate: 6_000.0, wage_index: 1.0
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: fiscal_year, locality: cbsa, base_rate: 6_000.0, wage_index: wage_index
    )
  end

  def seed_opps_national_rows(calendar_year:)
    Corvid::OppsApcWeight.create!(
      calendar_year: calendar_year, apc_code: "5071", relative_weight: 25.4378
    )
    Corvid::OppsConversionFactor.create!(
      calendar_year: calendar_year, locality: "NATIONAL",
      conversion_factor: 70.0, wage_index: 1.0
    )
  end

  def seed_asc_national_rows(calendar_year:)
    Corvid::AscHcpcsRate.create!(
      calendar_year: calendar_year, hcpcs_code: "12345",
      payment_indicator: "G2", payment_weight: 20.0
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: calendar_year, locality: "NATIONAL",
      conversion_factor: 42.0, wage_index: 1.0
    )
  end

  def expected_opps_national_rate
    (BigDecimal("25.4378") * 70.0 * 1.0).round(2).to_f
  end

  def analyze_with_facility(facility_code:, procedure:, paid:, service_date: TEST_DATE, vendor_id: "V01")
    paid_str = format("%.2f", paid)
    sample = <<~PRC
      H^PRC_EXPORT^#{facility_code}^#{service_date.strftime("%Y%m%d")}^1
      O^OBL-WAGE-1^DFN001^#{vendor_id}^#{procedure}^#{service_date.strftime("%Y%m%d")}^A^#{paid_str}^#{paid_str}^0.00^0.00^#{service_date.year}
      T^1^1^0^#{paid_str}^0.00
    PRC
    report = Corvid::PrcReportParser.parse(sample)
    Corvid::PrcOverpaymentAnalyzer.analyze(report)
  end

  def seed_pfs_rate(cpt:, rate_components:)
    Corvid::FeeScheduleEntry.create!(
      cpt_code: cpt,
      locality: rate_components[:locality],
      effective_date: rate_components[:effective_date],
      work_rvu: rate_components[:work_rvu],
      work_gpci: rate_components[:work_gpci],
      pe_rvu: rate_components[:pe_rvu],
      pe_gpci: rate_components[:pe_gpci],
      mp_rvu: rate_components[:mp_rvu],
      mp_gpci: rate_components[:mp_gpci],
      conversion_factor: rate_components[:conversion_factor],
      release_label: rate_components[:release_label]
    )
  end

  def hip_27130_inputs
    {
      locality: TEST_LOCALITY, effective_date: TEST_DATE,
      work_rvu: 20.0, work_gpci: 1.0, pe_rvu: 10.0, pe_gpci: 1.0,
      mp_rvu: 1.0, mp_gpci: 1.0, conversion_factor: 36.0,
      release_label: "test_hip"
    }
  end

  def office_99213_inputs
    {
      locality: TEST_LOCALITY, effective_date: TEST_DATE,
      work_rvu: 0.97, work_gpci: 1.0, pe_rvu: 0.85, pe_gpci: 1.0,
      mp_rvu: 0.07, mp_gpci: 1.0, conversion_factor: 36.0,
      release_label: "test_office"
    }
  end
end
