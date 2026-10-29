# frozen_string_literal: true

require "csv"

When("I import and reanalyze an outpatient PRC obligation {string} at facility {string} on {string}") do |obligation_id, facility, on|
  @audit_tenant ||= "tnt_audit_wage_area"
  service_date = Date.parse(on)
  paid_str = "5000.00"
  export = <<~PRC
    H^PRC_EXPORT^#{facility}^#{service_date.strftime("%Y%m%d")}^1
    O^#{obligation_id}^DFN001^VEND-HOSP^OUTPATIENT_AUDIT^#{service_date.strftime("%Y%m%d")}^A^#{paid_str}^#{paid_str}^0.00^0.00^#{service_date.year}
    T^1^1^0^#{paid_str}^0.00
  PRC
  Corvid::TenantContext.with_tenant(@audit_tenant) do
    Corvid::PrcImporter.import(export, source_file: "audit_wage_area.prc")
    Corvid::PrcImporter.reanalyze(tenant: @audit_tenant)
  end
end

When("I export an audit packet detail CSV for tenant {string}") do |tenant|
  packet = Corvid::PrcOverpaymentReportService.to_audit_packet(tenant: tenant)
  @audit_detail_csv = CSV.parse(packet["detail.csv"], headers: true)
end

Then("the detail CSV row for obligation {string} has wage_area {string}") do |obligation_id, expected|
  row = @audit_detail_csv.find { |r| r["obligation_id"] == obligation_id }
  refute_nil row, "expected obligation #{obligation_id} in detail.csv"
  assert_equal expected, row["wage_area"]
end

Then("the detail CSV row for obligation {string} has crosswalk_release {string}") do |obligation_id, expected|
  row = @audit_detail_csv.find { |r| r["obligation_id"] == obligation_id }
  refute_nil row, "expected obligation #{obligation_id} in detail.csv"
  assert_equal expected, row["crosswalk_release"]
end
