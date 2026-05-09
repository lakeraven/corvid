# frozen_string_literal: true

require "test_helper"
require "csv"
require "json"

class Corvid::PrcOverpaymentReportServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_report_test"

  # Fixture: two obligations across two FYs / two vendors / two payment
  # systems. Distinct paid_amount + overpayment values keep the totals
  # easy to assert against without arithmetic ambiguity.
  setup do
    Corvid::TenantContext.with_tenant(TENANT) do
      hip = Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-A",
        vendor_id: "VEND-HOSP",
        procedure_code: "HIP_REPLACE_THR",
        service_date: Date.new(2009, 5, 4),
        billed_amount: 65_000, paid_amount: 42_000,
        savings: 23_000, balance: 0, fiscal_year: 2009,
        source_file: "fy09.prc", imported_at: Time.current
      )
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: hip,
        analyzer_version: "phase_1.5",
        rate_source_release: "ipps_stub_v1",
        payment_system: "ipps", rate_source: "stub",
        recovery_confidence: "stub_estimate",
        medicare_equivalent: 18_000, overpayment: 24_000,
        analyzed_at: Time.current
      )

      visit = Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-B",
        vendor_id: "VEND-CLINIC",
        procedure_code: "OFFICE_VISIT_EST",
        service_date: Date.new(2010, 6, 1),
        billed_amount: 200, paid_amount: 180,
        savings: 20, balance: 0, fiscal_year: 2010,
        source_file: "fy10.prc", imported_at: Time.current
      )
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: visit,
        analyzer_version: "phase_1.5",
        rate_source_release: "pfs_2010",
        payment_system: "pfs", rate_source: "real",
        recovery_confidence: "clear",
        medicare_equivalent: 100, overpayment: 80,
        analyzed_at: Time.current
      )
    end
  end

  # -- Summary ----------------------------------------------------------------

  test "summary aggregates totals across all obligations" do
    summary = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT)

    assert_equal 2, summary[:obligations_analyzed]
    assert_equal 65_200.to_d, summary[:total_billed]
    assert_equal 42_180.to_d, summary[:total_paid]
    assert_equal 18_100.to_d, summary[:total_medicare_equivalent]
    assert_equal 80.to_d, summary[:total_overpayment_known],
                 "clear-confidence overpayment is the recoverable-now total"
    assert_equal 24_000.to_d, summary[:total_overpayment_stub_estimate],
                 "stub-confidence overpayment is directional, not yet recoverable"
  end

  test "summary breaks down by payment_system, vendor, and fiscal_year" do
    summary = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT)

    assert_equal 2, summary[:by_payment_system].size
    ipps_row = summary[:by_payment_system].find { |r| r[:payment_system] == "ipps" }
    assert_equal 1, ipps_row[:obligations]
    assert_equal 24_000.to_d, ipps_row[:overpayment]

    assert_equal 2, summary[:by_vendor].size
    assert_equal 2, summary[:by_year].size
  end

  test "summary filters by fiscal_year" do
    summary = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT, year: 2009)
    assert_equal 1, summary[:obligations_analyzed]
    assert_equal 0.to_d, summary[:total_overpayment_known]
    assert_equal 24_000.to_d, summary[:total_overpayment_stub_estimate]
  end

  test "summary filters by recovery_confidence" do
    summary = Corvid::PrcOverpaymentReportService.summary(
      tenant: TENANT, recovery_confidence: "clear"
    )
    assert_equal 1, summary[:obligations_analyzed]
    assert_equal 80.to_d, summary[:total_overpayment_known]
  end

  test "summary filters by payment_system and vendor_id" do
    summary = Corvid::PrcOverpaymentReportService.summary(
      tenant: TENANT, payment_system: "pfs", vendor_id: "VEND-CLINIC"
    )
    assert_equal 1, summary[:obligations_analyzed]
  end

  # -- Detail rows ------------------------------------------------------------

  test "detail returns one row per analyzed obligation with provenance fields" do
    rows = Corvid::PrcOverpaymentReportService.detail(tenant: TENANT)

    assert_equal 2, rows.size
    hip_row = rows.find { |r| r[:obligation_id] == "OBL-A" }
    assert_equal "ipps", hip_row[:payment_system]
    assert_equal "stub", hip_row[:rate_source]
    assert_equal "ipps_stub_v1", hip_row[:rate_source_release]
    assert_equal "phase_1.5", hip_row[:analyzer_version]
    assert_equal "fy09.prc", hip_row[:source_file]
    assert_equal "stub_estimate", hip_row[:recovery_confidence]
    assert_equal 24_000.to_d, hip_row[:overpayment]
  end

  test "detail uses each obligation's most recent analysis when history exists" do
    Corvid::TenantContext.with_tenant(TENANT) do
      hip = Corvid::PrcObligation.find_by(obligation_id: "OBL-A")
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: hip,
        analyzer_version: "phase_2.0",
        rate_source_release: "ipps_real_2009",
        payment_system: "ipps", rate_source: "real",
        recovery_confidence: "clear",
        medicare_equivalent: 22_000, overpayment: 20_000,
        analyzed_at: 1.minute.from_now
      )
    end

    rows = Corvid::PrcOverpaymentReportService.detail(tenant: TENANT)
    hip_row = rows.find { |r| r[:obligation_id] == "OBL-A" }
    assert_equal "phase_2.0", hip_row[:analyzer_version]
    assert_equal "clear", hip_row[:recovery_confidence]
    assert_equal 20_000.to_d, hip_row[:overpayment]
  end

  # -- CSV outputs ------------------------------------------------------------

  test "to_csv_summary emits header + one row per (year, vendor, payment_system)" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_summary(tenant: TENANT)
    table = CSV.parse(csv, headers: true)

    assert_includes table.headers, "fiscal_year"
    assert_includes table.headers, "vendor_id"
    assert_includes table.headers, "payment_system"
    assert_includes table.headers, "total_overpayment_known"
    assert_includes table.headers, "total_overpayment_stub_estimate"
    assert_equal 2, table.size
  end

  test "to_csv_detail emits one row per obligation with provenance columns" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_detail(tenant: TENANT)
    table = CSV.parse(csv, headers: true)

    %w[obligation_id payment_system recovery_confidence overpayment
       analyzer_version rate_source rate_source_release source_file].each do |col|
      assert_includes table.headers, col
    end
    assert_equal 2, table.size
    hip_row = table.find { |r| r["obligation_id"] == "OBL-A" }
    assert_equal "ipps", hip_row["payment_system"]
    assert_equal "fy09.prc", hip_row["source_file"]
  end

  test "CSV output respects filters" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_detail(
      tenant: TENANT, recovery_confidence: "clear"
    )
    table = CSV.parse(csv, headers: true)
    assert_equal 1, table.size
    assert_equal "OBL-B", table[0]["obligation_id"]
  end

  # -- JSON export ------------------------------------------------------------

  test "to_json_export bundles summary + detail + filters + provenance" do
    json = Corvid::PrcOverpaymentReportService.to_json_export(
      tenant: TENANT, year: 2010
    )
    parsed = JSON.parse(json)

    assert_equal TENANT, parsed["tenant"]
    assert_equal({ "year" => 2010 }, parsed["filters"])
    refute_nil parsed["generated_at"]
    assert_equal 1, parsed["summary"]["obligations_analyzed"]
    assert_equal 1, parsed["detail"].size
    assert_equal "OBL-B", parsed["detail"][0]["obligation_id"]
    assert_equal "phase_1.5", parsed["detail"][0]["analyzer_version"]
  end

  # -- Deterministic output ---------------------------------------------------

  test "detail orders rows by (fiscal_year, vendor_id, payment_system, obligation_id)" do
    Corvid::TenantContext.with_tenant(TENANT) do
      # Insert in non-sorted order to ensure ordering isn't insertion-coincidence
      [ "OBL-Z", "OBL-M", "OBL-A2" ].each_with_index do |id, i|
        ob = Corvid::PrcObligation.create!(
          facility_identifier: "SEA",
          obligation_id: id,
          vendor_id: "VEND-Z",
          billed_amount: 1, paid_amount: 1, fiscal_year: 2020,
          imported_at: Time.current
        )
        Corvid::PrcOverpaymentAnalysis.create!(
          prc_obligation: ob,
          analyzer_version: "phase_1.5",
          payment_system: "pfs", recovery_confidence: "clear",
          medicare_equivalent: 1, overpayment: 0,
          analyzed_at: Time.current + i.seconds
        )
      end
    end

    rows1 = Corvid::PrcOverpaymentReportService.detail(tenant: TENANT)
    rows2 = Corvid::PrcOverpaymentReportService.detail(tenant: TENANT)
    assert_equal rows1.map { |r| r[:obligation_id] }, rows2.map { |r| r[:obligation_id] },
                 "two consecutive exports of unchanged data are byte-equal"

    fy_2020 = rows1.select { |r| r[:fiscal_year] == 2020 }
    assert_equal [ "OBL-A2", "OBL-M", "OBL-Z" ],
                 fy_2020.map { |r| r[:obligation_id] },
                 "rows within a year sort by obligation_id"
  end

  test "summary CSV orders groups deterministically" do
    csv1 = Corvid::PrcOverpaymentReportService.to_csv_summary(tenant: TENANT)
    csv2 = Corvid::PrcOverpaymentReportService.to_csv_summary(tenant: TENANT)
    assert_equal csv1, csv2, "summary CSV is byte-stable across runs"
  end

  # -- Money formatting -------------------------------------------------------

  test "CSV money fields are fixed-point decimals, not BigDecimal scientific notation" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_detail(tenant: TENANT)
    table = CSV.parse(csv, headers: true)

    table.each do |row|
      %w[billed_amount paid_amount medicare_equivalent overpayment].each do |col|
        next if row[col].nil? || row[col].empty?
        refute_match(/E/i, row[col],
                     "#{col}=#{row[col].inspect} should be fixed-point, not scientific")
        assert_match(/\A-?\d+\.\d{2}\z/, row[col],
                     "#{col} should be N.NN format")
      end
    end
  end

  test "summary CSV money totals are fixed-point decimals" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_summary(tenant: TENANT)
    table = CSV.parse(csv, headers: true)
    money_cols = %w[total_billed total_paid total_medicare_equivalent
                    total_overpayment_known total_overpayment_stub_estimate]
    table.each do |row|
      money_cols.each do |col|
        refute_match(/E/i, row[col].to_s,
                     "summary #{col}=#{row[col].inspect} should be fixed-point")
      end
    end
  end

  test "JSON money fields are fixed-point strings" do
    json = Corvid::PrcOverpaymentReportService.to_json_export(tenant: TENANT)
    parsed = JSON.parse(json)

    parsed["detail"].each do |row|
      %w[billed_amount paid_amount medicare_equivalent overpayment].each do |col|
        next if row[col].nil?
        assert_kind_of String, row[col]
        refute_match(/E/i, row[col], "#{col} should not be scientific")
        assert_match(/\A-?\d+\.\d{2}\z/, row[col])
      end
    end

    %w[total_billed total_paid total_medicare_equivalent
       total_overpayment_known total_overpayment_stub_estimate].each do |col|
      assert_kind_of String, parsed["summary"][col]
      refute_match(/E/i, parsed["summary"][col])
    end
  end

  # -- Filter naming (fiscal_year vs year alias) ------------------------------

  test "fiscal_year: filter selects the federal-fiscal-year column" do
    summary = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT, fiscal_year: 2009)
    assert_equal 1, summary[:obligations_analyzed]
  end

  test "year: is accepted as a backward-compatible alias for fiscal_year:" do
    by_alias = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT, year: 2009)
    by_canon = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT, fiscal_year: 2009)
    assert_equal by_canon[:obligations_analyzed], by_alias[:obligations_analyzed]
  end

  # -- Tenant scoping ---------------------------------------------------------

  test "report is tenant-scoped — rows from other tenants are excluded" do
    Corvid::TenantContext.with_tenant("tnt_other") do
      ob = Corvid::PrcObligation.create!(
        facility_identifier: "OTH",
        obligation_id: "OBL-OTHER",
        billed_amount: 1, paid_amount: 1, fiscal_year: 2009,
        imported_at: Time.current
      )
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_1.5",
        recovery_confidence: "clear",
        medicare_equivalent: 1, overpayment: 0,
        analyzed_at: Time.current
      )
    end

    summary = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT)
    assert_equal 2, summary[:obligations_analyzed],
                 "other tenants do not bleed into this tenant's report"
  end

  # -- Obligations without analyses ------------------------------------------

  test "obligations with no analysis row are excluded from the report" do
    Corvid::TenantContext.with_tenant(TENANT) do
      Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-NO-ANALYSIS",
        billed_amount: 999, paid_amount: 0, fiscal_year: 2011,
        imported_at: Time.current
      )
    end

    rows = Corvid::PrcOverpaymentReportService.detail(tenant: TENANT)
    refute_includes rows.map { |r| r[:obligation_id] }, "OBL-NO-ANALYSIS"
  end
end
