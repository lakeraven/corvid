# frozen_string_literal: true

require "csv"
require "json"

Given("a tenant {string} with persisted PRC analyses:") do |tenant, table|
  @report_tenant = tenant
  Corvid::TenantContext.with_tenant(tenant) do
    table.hashes.each do |row|
      obligation = Corvid::PrcObligation.create!(
        facility_identifier: "FAC",
        obligation_id: row["obligation_id"],
        vendor_id: row["vendor_id"],
        billed_amount: row["overpayment"].to_d * 2,
        paid_amount: row["overpayment"].to_d,
        fiscal_year: row["fiscal_year"].to_i,
        service_date: Date.new(row["fiscal_year"].to_i, 5, 1),
        source_file: "fy#{row['fiscal_year']}.prc",
        imported_at: Time.current
      )
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: obligation,
        analyzer_version: "phase_1.5",
        rate_source_release: "release_#{row['fiscal_year']}",
        payment_system: row["payment_system"],
        rate_source: row["recovery_confidence"] == "clear" ? "real" : "stub",
        recovery_confidence: row["recovery_confidence"],
        medicare_equivalent: row["overpayment"].to_d,
        overpayment: row["overpayment"].to_d,
        analyzed_at: Time.current
      )
    end
  end
end

When("I export a summary CSV for {string}") do |tenant|
  @report_csv = Corvid::PrcOverpaymentReportService.to_csv_summary(tenant: tenant)
  @report_table = CSV.parse(@report_csv, headers: true)
end

When("I export a detail CSV for {string}") do |tenant|
  @report_csv = Corvid::PrcOverpaymentReportService.to_csv_detail(tenant: tenant)
  @report_table = CSV.parse(@report_csv, headers: true)
end

When("I export a detail CSV for {string} filtered to recovery_confidence {string}") do |tenant, conf|
  @report_csv = Corvid::PrcOverpaymentReportService.to_csv_detail(
    tenant: tenant, recovery_confidence: conf
  )
  @report_table = CSV.parse(@report_csv, headers: true)
end

When("I export the report as JSON for {string} filtered to fiscal year {int}") do |tenant, year|
  @report_json = Corvid::PrcOverpaymentReportService.to_json_export(
    tenant: tenant, year: year
  )
  @report_parsed = JSON.parse(@report_json)
end

Then("the CSV includes columns for total_overpayment_known and total_overpayment_excluded_stub") do
  assert_includes @report_table.headers, "total_overpayment_known"
  assert_includes @report_table.headers, "total_overpayment_excluded_stub"
end

Then("there is one row per fiscal_year + vendor_id + payment_system grouping") do
  groups = @report_table.map { |r| [ r["fiscal_year"], r["vendor_id"], r["payment_system"] ] }
  assert_equal groups.size, groups.uniq.size, "rows should be uniquely grouped"
  assert @report_table.size >= 1
end

Then("every row carries analyzer_version, rate_source, and rate_source_release") do
  @report_table.each do |row|
    refute_nil row["analyzer_version"]
    refute_nil row["rate_source"]
    refute_nil row["rate_source_release"]
  end
end

Then("every row carries the source_file the obligation was imported from") do
  @report_table.each { |row| refute_nil row["source_file"] }
end

Then("the JSON includes a generated_at timestamp") do
  refute_nil @report_parsed["generated_at"]
end

Then("the JSON detail contains exactly the 2010 obligations") do
  assert_equal 1, @report_parsed["detail"].size
  assert_equal 2010, @report_parsed["detail"][0]["fiscal_year"]
end

Then("the JSON filters reflect the year filter") do
  assert_equal 2010, @report_parsed["filters"]["year"]
end

Then("only obligations with clear-confidence analyses appear in the output") do
  @report_table.each { |row| assert_equal "clear", row["recovery_confidence"] }
  assert @report_table.size >= 1
end
