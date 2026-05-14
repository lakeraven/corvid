# frozen_string_literal: true

Given("the fee schedule contains:") do |table|
  table.hashes.each do |row|
    Corvid::FeeScheduleEntry.create!(
      cpt_code: row["cpt_code"],
      locality: row["locality"],
      work_rvu: row["work_rvu"].to_f,
      pe_rvu: row["pe_rvu"].to_f,
      mp_rvu: row["mp_rvu"].to_f,
      work_gpci: row["work_gpci"].to_f,
      pe_gpci: row["pe_gpci"].to_f,
      mp_gpci: row["mp_gpci"].to_f,
      conversion_factor: row["conversion_factor"].to_f,
      effective_date: Date.parse(row["effective_date"])
    )
  end
end

Given("ZIP {string} maps to locality {string}") do |zip, locality|
  Corvid::ZipLocality.create!(zip_code: zip, locality: locality)
  Corvid::LocalityLookup.clear_cache!
end

When("I reprice CPT {string} in ZIP {string}") do |cpt, zip|
  @result = reprice_professional_claim(cpt_code: cpt, zip: zip)
end

When("I reprice CPT {string} in ZIP {string} with billed amount {float}") do |cpt, zip, amount|
  @result = reprice_professional_claim(cpt_code: cpt, zip: zip, billed_amount: amount)
end

When("I batch reprice:") do |table|
  claims = table.hashes.map { |row| row.transform_keys(&:to_sym) }
  @batch_results = claims.filter_map do |claim|
    reprice_professional_claim(
      cpt_code: claim[:cpt_code].to_s,
      zip: claim[:zip].to_s,
      billed_amount: claim[:billed_amount]&.to_f
    )
  end
end

When("I audit these claims:") do |table|
  claims = table.hashes.map { |row| row.transform_keys(&:to_sym) }
  results = claims.filter_map do |claim|
    reprice_professional_claim(
      cpt_code: claim[:cpt_code].to_s,
      zip: claim[:zip].to_s,
      billed_amount: claim[:billed_amount]&.to_f
    )
  end
  total_billed = results.sum { |r| r.billed_amount || 0 }
  total_overpayment = results.sum { |r| r.savings || 0 }
  @audit = {
    claims_analyzed: results.length,
    total_overpayment: total_overpayment.round(2),
    total_billed: total_billed.round(2)
  }
end

Then("the Medicare rate should be calculated") do
  refute_nil @result
  assert @result.medicare_rate.positive?
end

Then("the rate should be greater than {int}") do |amount|
  assert @result.medicare_rate > amount
end

Then("the Medicare rate should be less than {float}") do |amount|
  assert @result.medicare_rate < amount
end

Then("the savings should be positive") do
  assert @result.savings.positive?
end

Then("no rate should be found") do
  assert_nil @result
end

Then("{int} claims should be repriced") do |count|
  assert_equal count, @batch_results.length
end

Then("each result should have a Medicare rate") do
  @batch_results.each { |r| assert r.medicare_rate.positive? }
end

Then("the audit should show total overpayment greater than {int}") do |amount|
  assert @audit[:total_overpayment] > amount
end

Then("the audit should report {int} claims analyzed") do |count|
  assert_equal count, @audit[:claims_analyzed]
end

RepricingStepResult = Struct.new(
  :cpt_code, :medicare_rate, :locality, :effective_date,
  :billed_amount, :savings,
  keyword_init: true
)

def reprice_professional_claim(cpt_code:, zip:, date: Date.current, billed_amount: nil)
  locality = Corvid::LocalityLookup.for_zip(zip)
  return nil unless locality

  entry = Corvid::FeeScheduleEntry.rate_for(cpt_code: cpt_code, locality: locality, date: date)
  return nil unless entry

  rate = BigDecimal(entry.medicare_rate.to_s).round(2)
  billed = billed_amount.nil? ? nil : BigDecimal(billed_amount.to_s)
  RepricingStepResult.new(
    cpt_code: cpt_code,
    medicare_rate: rate,
    locality: locality,
    effective_date: entry.effective_date,
    billed_amount: billed,
    savings: billed ? [ (billed - rate).round(2), BigDecimal("0") ].max : nil
  )
end
