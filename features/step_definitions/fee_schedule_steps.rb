# frozen_string_literal: true

# Sliding fee scale step definitions (ported from rpms_redux)

Given("a fee schedule exists with tiers:") do |table|
  tiers = table.hashes.map do |row|
    { fpl_percentage: row["fpl_percentage"].to_i,
      discount_percentage: row["discount_percentage"].to_i,
      label: row["label"] || "#{row['fpl_percentage']}% FPL" }
  end
  @fee_schedule = Corvid::FeeSchedule.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    name: "Standard Sliding Fee",
    tiers_token: Corvid.adapter.store_text(
      case_token: "fs_test", kind: :note, text: tiers.to_json
    ),
    effective_date: Date.new(Date.current.year, 1, 1),
    active: true
  )
end

Given("a fee schedule {string} exists") do |name|
  @fee_schedule = Corvid::FeeSchedule.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    name: name,
    effective_date: Date.new(Date.current.year, 1, 1),
    active: true
  )
end

When("I look up the discount for {int}% FPL") do |fpl|
  tiers_json = Corvid.adapter.fetch_text(@fee_schedule.tiers_token)
  tiers = tiers_json ? JSON.parse(tiers_json, symbolize_names: true) : []
  @discount = tiers.select { |t| fpl <= t[:fpl_percentage] }
                   .min_by { |t| t[:fpl_percentage] }
                   &.dig(:discount_percentage) || 0
end

When("I calculate the fee for a {string} service at {string}") do |_service, base_amount|
  @base_amount = base_amount.gsub("$", "").to_f
  @calculated_fee = @base_amount * (1 - @discount / 100.0)
end

Then("the discount should be {int}%") do |expected|
  assert_equal expected, @discount
end

Then("the patient fee should be {string}") do |expected|
  assert_in_delta expected.gsub("$", "").to_f, @calculated_fee, 0.01
end

Then("the fee schedule should be active") do
  assert @fee_schedule.active
end

Then("the fee schedule should have an effective date") do
  refute_nil @fee_schedule.effective_date
end
