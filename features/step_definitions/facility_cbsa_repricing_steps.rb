# frozen_string_literal: true

Given("CMS OPPS rates for calendar year {int} are loaded for APC {string}") do |year, apc|
  Corvid::OppsApcWeight.create!(
    calendar_year: year, apc_code: apc, relative_weight: 25.4378,
    release_label: "cucumber_opps_#{year}"
  )
  Corvid::OppsConversionFactor.create!(
    calendar_year: year, locality: "NATIONAL",
    conversion_factor: 70.0, wage_index: 1.0,
    release_label: "cucumber_opps_#{year}"
  )
end

Given("the IPPS wage index for fiscal year {int} locality {string} is {float}") do |year, locality, wage_index|
  attrs = {
    fiscal_year: year, locality: locality,
    base_rate: 6_000.0, wage_index: wage_index,
    release_label: "cucumber_wage_#{year}"
  }
  existing = Corvid::IppsHospitalRate.find_by(fiscal_year: year, locality: locality)
  if existing
    existing.update!(wage_index: wage_index)
  else
    Corvid::IppsHospitalRate.create!(attrs)
  end
end

Given("an outpatient PRC procedure {string} maps HCPCS {string} to APC {string}") do |code, hcpcs, apc|
  Corvid::PrcProcedureDictionary.register(
    code, hcpcs: hcpcs, apc: apc, description: "Synthetic outpatient procedure"
  )
end

When("I analyze an outpatient PRC obligation at facility {string} on {string} with paid amount {float}") do |facility, on, paid|
  service_date = Date.parse(on)
  paid_str = format("%.2f", paid)
  sample = <<~PRC
    H^PRC_EXPORT^#{facility}^#{service_date.strftime("%Y%m%d")}^1
    O^OBL-CBSA-CUKE^DFN001^VEND-HOSP^OUTPATIENT_CBSA^#{service_date.strftime("%Y%m%d")}^A^#{paid_str}^#{paid_str}^0.00^0.00^#{service_date.year}
    T^1^1^0^#{paid_str}^0.00
  PRC
  report = Corvid::PrcReportParser.parse(sample)
  @analyzer_result = Corvid::PrcOverpaymentAnalyzer.analyze(report).results.first
end

Then("the analyzer medicare equivalent should be {float}") do |expected|
  refute_nil @analyzer_result, "analyzer produced no result"
  assert_in_delta expected, @analyzer_result.medicare_equivalent.to_f, 0.01
end
