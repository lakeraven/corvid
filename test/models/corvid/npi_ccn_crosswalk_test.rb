# frozen_string_literal: true

require "test_helper"

class Corvid::NpiCcnCrosswalkTest < ActiveSupport::TestCase
  test "valid row requires both npi and ccn" do
    row = Corvid::NpiCcnCrosswalk.new(npi: "1234567890", ccn: "451301")
    assert row.valid?
  end

  test "ccns_for returns matching ccn for an active NPI on the service date" do
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "451301",
      effective_date: Date.new(2015, 1, 1)
    )
    ccns = Corvid::NpiCcnCrosswalk.ccns_for(
      npi: "1234567890", on: Date.new(2024, 6, 1)
    )
    assert_equal [ "451301" ], ccns
  end

  test "ccns_for returns empty when NPI has no crosswalk row" do
    ccns = Corvid::NpiCcnCrosswalk.ccns_for(
      npi: "9999999999", on: Date.new(2024, 6, 1)
    )
    assert_equal [], ccns
  end

  test "ccns_for returns multiple CCNs when an NPI maps to several over time" do
    # Realistic case: organizational restructure — one NPI changes CCN.
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "451301",
      effective_date: Date.new(2015, 1, 1), end_date: Date.new(2019, 12, 31)
    )
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "451999",
      effective_date: Date.new(2020, 1, 1)
    )
    on_2024 = Corvid::NpiCcnCrosswalk.ccns_for(npi: "1234567890", on: Date.new(2024, 6, 1))
    assert_equal [ "451999" ], on_2024,
                 "service date 2024 should match the post-2020 row only"

    on_2018 = Corvid::NpiCcnCrosswalk.ccns_for(npi: "1234567890", on: Date.new(2018, 6, 1))
    assert_equal [ "451301" ], on_2018,
                 "service date 2018 should match the pre-2020 row only"
  end

  test "ccns_for returns empty when NPI is blank or service date is nil" do
    Corvid::NpiCcnCrosswalk.create!(npi: "1234567890", ccn: "451301")
    assert_equal [], Corvid::NpiCcnCrosswalk.ccns_for(npi: "", on: Date.current)
    assert_equal [], Corvid::NpiCcnCrosswalk.ccns_for(npi: "1234567890", on: nil)
  end

  test "ccns_for de-duplicates when the same (npi, ccn) is listed across multiple historical periods" do
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "451301",
      effective_date: Date.new(2015, 1, 1), end_date: Date.new(2017, 12, 31)
    )
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "451301",
      effective_date: Date.new(2018, 1, 1)
    )
    ccns = Corvid::NpiCcnCrosswalk.ccns_for(npi: "1234567890", on: Date.new(2024, 6, 1))
    assert_equal [ "451301" ], ccns
  end

  test "ccns_for returns only the latest source_release when multiple snapshots are loaded" do
    # Older NPPES snapshot mapped this NPI to one CCN…
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "111111",
      effective_date: Date.new(2020, 1, 1),
      source_release: "nppes_2025_q4"
    )
    # …a refreshed snapshot replaces it with a different CCN.
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "222222",
      effective_date: Date.new(2020, 1, 1),
      source_release: "nppes_2026_q1"
    )

    ccns = Corvid::NpiCcnCrosswalk.ccns_for(npi: "1234567890", on: Date.new(2024, 6, 1))

    assert_equal [ "222222" ], ccns,
                 "later snapshot is authoritative; stale row from older snapshot must not route claims"
  end
end
