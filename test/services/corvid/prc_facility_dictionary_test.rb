# frozen_string_literal: true

require "test_helper"

class Corvid::PrcFacilityDictionaryTest < ActiveSupport::TestCase
  def teardown
    Corvid::PrcFacilityDictionary.reset!
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
end
