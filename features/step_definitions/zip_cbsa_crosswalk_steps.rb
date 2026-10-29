# frozen_string_literal: true

require "rake"
require "tempfile"

Given("a zip-to-CBSA crosswalk CSV for fiscal year {int}:") do |year, table|
  @crosswalk_fiscal_year = year
  lines = [
    "# ZIP to CBSA crosswalk, FY #{year}",
    "# release_label: pending",
    "zip,cbsa"
  ]
  table.hashes.each do |row|
    lines << "#{row['zip']},#{row['cbsa']}"
  end
  @crosswalk_csv = Tempfile.new([ "zip_cbsa", ".csv" ])
  @crosswalk_csv.write(lines.join("\n"))
  @crosswalk_csv.close
end

When("I import the zip-to-CBSA crosswalk for fiscal year {int} with release label {string}") do |year, label|
  Rails.application.load_tasks if Rake::Task.tasks.empty?
  task = Rake::Task["cms:zip_cbsa:import"]
  task.reenable
  task.invoke(year.to_s, @crosswalk_csv.path, label)
  task.reenable
end

Given("the PRC facility dictionary maps code {string} to ZIP {string}") do |code, zip|
  Corvid::PrcFacilityDictionary.register(
    code,
    name: "Synthetic facility",
    city: "Test City",
    state: "TS",
    zip: zip,
    locality: "99"
  )
  @facility_zip = zip
end

Then("the CBSA for ZIP {string} on {string} should be {string}") do |zip, on, expected_cbsa|
  actual = Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: Date.parse(on))
  assert_equal expected_cbsa, actual
end
