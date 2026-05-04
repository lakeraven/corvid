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
  @result = Corvid::RepricingService.reprice(cpt_code: cpt, zip: zip)
end

When("I reprice CPT {string} in ZIP {string} with billed amount {float}") do |cpt, zip, amount|
  @result = Corvid::RepricingService.reprice(cpt_code: cpt, zip: zip, billed_amount: amount)
end

When("I batch reprice:") do |table|
  claims = table.hashes.map { |row| row.transform_keys(&:to_sym) }
  @batch_results = Corvid::RepricingService.reprice_batch(claims)
end

When("I audit these claims:") do |table|
  claims = table.hashes.map { |row| row.transform_keys(&:to_sym) }
  @audit = Corvid::RepricingService.audit(claims)
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
