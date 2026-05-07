# frozen_string_literal: true

require "test_helper"

class Corvid::PrcOverpaymentAnalyzerTest < ActiveSupport::TestCase
  TEST_LOCALITY = "02"
  TEST_DATE = Date.new(2009, 5, 4)

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

  # -- Inpatient hospital obligation (DRG-mapped) ---------------------------

  test "inpatient hospital claim is flagged facility_repricing_pending" do
    summary = analyze_single_obligation(procedure: "HIP_REPLACE_THR", paid: 42_000)
    result = summary.results.first

    assert_equal :ipps, result.payment_system
    assert_equal :facility_repricing_pending, result.recovery_confidence
    assert_nil result.overpayment, "overpayment must be nil until IPPS is ingested"
    assert_in_delta 1371.97, result.medicare_equivalent, 0.5,
                    "professional component should still be priced from PFS"
    assert_match(/IPPS/, result.notes)
  end

  test "inpatient summary aggregates pending dollars separately from clear overpayment" do
    summary = analyze_single_obligation(procedure: "HIP_REPLACE_THR", paid: 42_000)

    assert_equal 0.0, summary.total_overpayment_known,
                 "no clear overpayment without IPPS"
    assert_equal 42_000.0, summary.total_facility_repricing_pending
    assert_equal({ facility_repricing_pending: 1 }, summary.by_confidence)
  end

  # -- Professional-only obligation (no DRG) --------------------------------

  test "professional-only office visit reprices to a clear overpayment" do
    summary = analyze_single_obligation(procedure: "OFFICE_VISIT_EST", paid: 250)
    result = summary.results.first

    assert_equal :pfs, result.payment_system
    assert_equal :clear, result.recovery_confidence
    refute_nil result.medicare_equivalent
    assert result.overpayment.positive?,
           "expected positive overpayment when paid > Medicare rate"
    assert_in_delta 250 - result.medicare_equivalent, result.overpayment, 0.01
  end

  test "professional-only when paid is below Medicare rate clamps overpayment to zero" do
    summary = analyze_single_obligation(procedure: "OFFICE_VISIT_EST", paid: 50)
    result = summary.results.first

    assert_equal :clear, result.recovery_confidence
    assert_equal 0, result.overpayment, "underpayment is not a recoverable overpayment"
  end

  # -- Unmapped inputs -------------------------------------------------------

  test "unmapped procedure code yields :unmapped_procedure" do
    summary = analyze_single_obligation(procedure: "TOTALLY_UNKNOWN_CODE", paid: 1000)
    result = summary.results.first

    assert_equal :unmapped_procedure, result.recovery_confidence
    assert_nil result.medicare_equivalent
    assert_match(/PrcProcedureDictionary/, result.notes)
  end

  test "unmapped facility code yields :unmapped_facility" do
    sample = <<~PRC
      H^PRC_EXPORT^XYZ^20090506^1
      O^OBL-1^DFN1^V1^OFFICE_VISIT_EST^20090504^A^200.00^180.00^20.00^0.00^2009
      T^1^1^0^180.00^0.00
    PRC
    report = Corvid::PrcReportParser.parse(sample)
    summary = Corvid::PrcOverpaymentAnalyzer.analyze(report)
    result = summary.results.first

    assert_equal :unmapped_facility, result.recovery_confidence
    assert_match(/locality/i, result.notes)
  end

  # -- No PFS data for the service date -------------------------------------

  test "missing fee schedule row yields :no_rate_for_year" do
    # Setup seeds rows with effective_date 2009-05-04. Querying for a date
    # *before* any seeded effective_date returns no rows (rate_for selects
    # the latest effective_date ≤ the service date).
    summary = analyze_single_obligation(
      procedure: "OFFICE_VISIT_EST", paid: 250,
      service_date: Date.new(2000, 1, 1)
    )
    result = summary.results.first

    assert_equal :no_rate_for_year, result.recovery_confidence
    assert_nil result.medicare_equivalent
  end

  # -- Helpers ---------------------------------------------------------------

  private

  def analyze_single_obligation(procedure:, paid:, service_date: TEST_DATE)
    paid_str = format("%.2f", paid)
    sample = <<~PRC
      H^PRC_EXPORT^SEA^#{service_date.strftime("%Y%m%d")}^1
      O^OBL-TEST-1^DFN001^V01^#{procedure}^#{service_date.strftime("%Y%m%d")}^A^#{paid_str}^#{paid_str}^0.00^0.00^#{service_date.year}
      T^1^1^0^#{paid_str}^0.00
    PRC
    report = Corvid::PrcReportParser.parse(sample)
    Corvid::PrcOverpaymentAnalyzer.analyze(report)
  end

  def seed_pfs_rate(cpt:, rate_components:)
    Corvid::FeeScheduleEntry.create!(
      cpt_code: cpt,
      locality: TEST_LOCALITY,
      effective_date: TEST_DATE,
      **rate_components
    )
  end

  # Real CMS 2009 PFS row for CPT 27130 in locality 02 (Seattle metro).
  # Locks the analyzer's expected output to actual published data.
  def hip_27130_inputs
    {
      work_rvu: 21.61,
      pe_rvu: 12.58,
      mp_rvu: 3.51,
      work_gpci: 1.014,
      pe_gpci: 1.085,
      mp_gpci: 0.706,
      conversion_factor: 36.0666
    }
  end

  # Office visit, established patient, level 3. Approximate 2009 row.
  def office_99213_inputs
    {
      work_rvu: 0.92,
      pe_rvu: 0.74,
      mp_rvu: 0.07,
      work_gpci: 1.014,
      pe_gpci: 1.085,
      mp_gpci: 0.706,
      conversion_factor: 36.0666
    }
  end
end
