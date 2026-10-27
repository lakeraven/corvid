# frozen_string_literal: true

require "test_helper"

class Corvid::PrcFacilityDictionaryTest < ActiveSupport::TestCase
  def teardown
    Corvid::PrcFacilityDictionary.reset!
    cleanup_zip_cbsa_crosswalk_rows!
  end

  def cleanup_zip_cbsa_crosswalk_rows!
    return unless Corvid.const_defined?(:ZipCbsaCrosswalk, false)

    Corvid::ZipCbsaCrosswalk.unscoped.delete_all
  rescue ActiveRecord::StatementInvalid
    nil
  end

  test "ships built-in mapping for SEA (Seattle) with locality 02" do
    entry = Corvid::PrcFacilityDictionary.lookup("SEA")
    assert_equal "Seattle", entry.city
    assert_equal "WA", entry.state
    assert_equal "02", entry.locality
  end

  test "lookup returns nil for unknown facility code" do
    assert_nil Corvid::PrcFacilityDictionary.lookup("XYZ")
  end

  test "host can register custom facility mappings" do
    Corvid::PrcFacilityDictionary.register(
      "CUSTOM",
      name: "Custom site",
      city: "Custom City",
      state: "OR",
      zip: "97000",
      locality: "01"
    )

    entry = Corvid::PrcFacilityDictionary.lookup("CUSTOM")
    assert_equal "Custom City", entry.city
    assert_equal "01", entry.locality
  end

  test "reset! restores defaults" do
    Corvid::PrcFacilityDictionary.register("TEMP", name: "Temp")
    assert Corvid::PrcFacilityDictionary.lookup("TEMP")

    Corvid::PrcFacilityDictionary.reset!

    assert_nil Corvid::PrcFacilityDictionary.lookup("TEMP")
    assert Corvid::PrcFacilityDictionary.lookup("SEA")
  end

  # ZIP → CBSA resolution (#371) — synthetic crosswalk rows only.

  test "cbsa_for returns a five-digit urban CBSA from a loaded crosswalk row" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88101", cbsa: "98765", release_label: "test"
    )

    assert_equal "98765",
                 Corvid::PrcFacilityDictionary.cbsa_for(zip: "88101", on: Date.new(2026, 1, 15))
  end

  test "cbsa_for returns a two-digit rural CMS state code from a loaded crosswalk row" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88202", cbsa: "12", release_label: "test"
    )

    assert_equal "12",
                 Corvid::PrcFacilityDictionary.cbsa_for(zip: "88202", on: Date.new(2026, 3, 1))
  end

  test "cbsa_for returns nil for a zip with no crosswalk row" do
    assert_nil Corvid::PrcFacilityDictionary.cbsa_for(zip: "88999", on: Date.new(2026, 1, 1))
  end

  test "cbsa_for uses only the first five digits of a ZIP+4" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88101", cbsa: "98765", release_label: "test"
    )

    assert_equal "98765",
                 Corvid::PrcFacilityDictionary.cbsa_for(zip: "88101-1234", on: Date.new(2026, 1, 1))
  end

  test "cbsa_for returns nil without raising for invalid zip inputs" do
    invalid = [ nil, "", "ABCDE", "8810", "881011", 88_101 ]
    invalid.each do |zip|
      assert_nil Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: Date.new(2026, 1, 1)),
                 "expected nil for zip=#{zip.inspect}"
    end
  end

  test "cbsa_for raises ArgumentError when on is not a Date" do
    assert_raises(ArgumentError) do
      Corvid::PrcFacilityDictionary.cbsa_for(zip: "88101", on: "2026-01-01")
    end
  end

  test "cbsa_for selects fiscal year from service date (Sept 30 vs Oct 1 boundary)" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2025, zip: "88303", cbsa: "55", release_label: "test"
    )
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88303", cbsa: "66666", release_label: "test"
    )

    assert_equal "55",
                 Corvid::PrcFacilityDictionary.cbsa_for(zip: "88303", on: Date.new(2025, 9, 30))
    assert_equal "66666",
                 Corvid::PrcFacilityDictionary.cbsa_for(zip: "88303", on: Date.new(2025, 10, 1))
  end

  test "cbsa_for does not fall back to another fiscal year when the target year has no rows" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88404", cbsa: "98765", release_label: "test"
    )

    assert_nil Corvid::PrcFacilityDictionary.cbsa_for(zip: "88404", on: Date.new(2024, 6, 1))
  end

  test "cbsa_for returns nil when no crosswalk data is loaded for any year" do
    assert_nil Corvid::PrcFacilityDictionary.cbsa_for(zip: "88101")
  end

  test "reset! clears cbsa_for memo so rows imported after reset are visible" do
    zip = "88505"
    Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: Date.new(2026, 1, 1))
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: zip, cbsa: "77777", release_label: "test"
    )

    assert_nil Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: Date.new(2026, 1, 1)),
               "memoized nil must persist until reset!"

    Corvid::PrcFacilityDictionary.reset!

    assert_equal "77777",
                 Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: Date.new(2026, 1, 1))
  end
end
