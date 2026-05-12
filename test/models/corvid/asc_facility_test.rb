# frozen_string_literal: true

require "test_helper"

class Corvid::AscFacilityTest < ActiveSupport::TestCase
  test "NPI-only row is valid: CMS feeds may key by NPI rather than CCN" do
    row = Corvid::AscFacility.new(
      npi: "1234567890", effective_date: Date.new(2020, 1, 1)
    )
    assert row.valid?
    row.save!
    assert Corvid::AscFacility.applies?(vendor_id: "1234567890", on: Date.new(2021, 6, 1))
  end

  test "row missing both ccn and npi is rejected" do
    row = Corvid::AscFacility.new(effective_date: Date.new(2020, 1, 1))
    refute row.valid?
    assert_match(/at least one of ccn or npi/, row.errors.full_messages.join)
  end

  test "applies? matches a vendor by either ccn or npi" do
    Corvid::AscFacility.create!(
      ccn: "451301", npi: "1234567890",
      effective_date: Date.new(2020, 1, 1)
    )
    assert Corvid::AscFacility.applies?(vendor_id: "451301", on: Date.new(2021, 6, 1))
    assert Corvid::AscFacility.applies?(vendor_id: "1234567890", on: Date.new(2021, 6, 1))
    refute Corvid::AscFacility.applies?(vendor_id: "OTHER", on: Date.new(2021, 6, 1))
  end

  test "ccn is unique scoped to effective_date so historical periods coexist" do
    Corvid::AscFacility.create!(
      ccn: "451301", effective_date: Date.new(2015, 1, 1), end_date: Date.new(2018, 12, 31)
    )
    later = Corvid::AscFacility.new(
      ccn: "451301", effective_date: Date.new(2020, 1, 1)
    )
    assert later.valid?

    dup = Corvid::AscFacility.new(
      ccn: "451301", effective_date: Date.new(2015, 1, 1)
    )
    refute dup.valid?
  end
end
