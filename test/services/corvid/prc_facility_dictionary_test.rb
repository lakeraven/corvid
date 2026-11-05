# frozen_string_literal: true

require "test_helper"

class Corvid::PrcFacilityDictionaryTest < ActiveSupport::TestCase
  setup do
    Corvid::PrcFacilityDictionary.reset!
    cleanup_zip_cbsa_crosswalk_rows!
  end

  def teardown
    Corvid::PrcFacilityDictionary.reset!
    cleanup_zip_cbsa_crosswalk_rows!
  end

  def cleanup_zip_cbsa_crosswalk_rows!
    return unless Corvid.const_defined?(:ZipCbsaCrosswalk, false)

    Corvid::ZipCbsaCrosswalk.unscoped.delete_all
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

  test "crosswalk_for returns the ZipCbsaCrosswalk row for a loaded zip and service date" do
    row = Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88101", cbsa: "98765", release_label: "cucumber_crosswalk"
    )
    on = Date.new(2026, 1, 15)

    assert_equal row, Corvid::PrcFacilityDictionary.crosswalk_for(zip: "88101", on: on)
    assert_equal "98765", Corvid::PrcFacilityDictionary.crosswalk_for(zip: "88101", on: on).cbsa
  end

  test "crosswalk_for returns nil when no row exists for the fiscal year" do
    assert_nil Corvid::PrcFacilityDictionary.crosswalk_for(zip: "88999", on: Date.new(2026, 1, 1))
  end

  test "crosswalk_for applies the same zip normalization and fiscal-year rules as cbsa_for" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2025, zip: "88303", cbsa: "55", release_label: "test"
    )
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88303", cbsa: "66666", release_label: "test"
    )

    assert_equal "55",
                 Corvid::PrcFacilityDictionary.crosswalk_for(
                   zip: "88303", on: Date.new(2025, 9, 30)
                 )&.cbsa
    assert_equal "66666",
                 Corvid::PrcFacilityDictionary.crosswalk_for(
                   zip: "88303-0001", on: Date.new(2025, 10, 1)
                 )&.cbsa
    assert_nil Corvid::PrcFacilityDictionary.crosswalk_for(zip: "88303abc", on: Date.new(2026, 1, 1))
  end

  test "cbsa_for returns crosswalk_for cbsa when a row is present" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88101", cbsa: "98765", release_label: "test"
    )
    on = Date.new(2026, 1, 15)

    crosswalk = Corvid::PrcFacilityDictionary.crosswalk_for(zip: "88101", on: on)
    assert_equal crosswalk&.cbsa, Corvid::PrcFacilityDictionary.cbsa_for(zip: "88101", on: on)
  end

  test "cbsa_for resolves a zip with a leading zero from an imported crosswalk row" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "01234", cbsa: "98765", release_label: "test"
    )

    assert_equal "98765",
                 Corvid::PrcFacilityDictionary.cbsa_for(zip: "01234", on: Date.new(2026, 1, 15))
  end

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

  # Gate H4: malformed zip strings never resolve even when a crosswalk row exists (issue #371 round 3).
  test "cbsa_for returns nil for malformed zips when crosswalk row exists for the five-digit prefix" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88101", cbsa: "98765", release_label: "test"
    )

    [ "881011", "88101abc", " 88101", "88101-12", "88101-12345" ].each do |zip|
      assert_nil Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: Date.new(2026, 1, 1)),
                 "expected nil for malformed zip=#{zip.inspect}"
    end
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

  test "cbsa_for does not cache misses; a row loaded after an earlier nil call is visible on the next call" do
    zip = "88505"
    on = Date.new(2026, 1, 1)

    assert_nil Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: on)

    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: zip, cbsa: "77777", release_label: "test"
    )

    assert_equal "77777", Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: on)
  end

  test "cbsa_for does not cache hits; a corrected crosswalk row is visible on the next call" do
    zip = "88506"
    on = Date.new(2026, 1, 1)
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: zip, cbsa: "98765", release_label: "test"
    )

    assert_equal "98765", Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: on)

    Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: zip).update!(cbsa: "11111")

    assert_equal "11111", Corvid::PrcFacilityDictionary.cbsa_for(zip: zip, on: on)
  end

  test "host register still resolves lookup after cbsa_for calls and crosswalk imports" do
    Corvid::PrcFacilityDictionary.register(
      "HOSTZIP",
      name: "Host site",
      city: "Host City",
      state: "OR",
      zip: "88607",
      locality: "01"
    )

    Corvid::PrcFacilityDictionary.cbsa_for(zip: "88999", on: Date.new(2026, 1, 1))
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88607", cbsa: "44444", release_label: "test"
    )
    Corvid::PrcFacilityDictionary.cbsa_for(zip: "88607", on: Date.new(2026, 1, 1))

    entry = Corvid::PrcFacilityDictionary.lookup("HOSTZIP")
    assert_equal "88607", entry.zip
    assert_equal "44444",
                 Corvid::PrcFacilityDictionary.cbsa_for(zip: entry.zip, on: Date.new(2026, 1, 1))
  end
end
