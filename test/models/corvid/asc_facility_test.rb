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

  test "applies? resolves an NPI vendor_id through the NPI↔CCN crosswalk to a CCN-keyed ASC row" do
    # CMS iQIES POS file gives us the ASC row keyed by CCN only; the
    # tribal PRC export may key vendor_id by NPI. Without the crosswalk,
    # the claim would route to OppsRateProvider instead of AscRateProvider.
    Corvid::AscFacility.create!(
      ccn: "451301", effective_date: Date.new(2015, 1, 1)
    )
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "451301",
      effective_date: Date.new(2015, 1, 1)
    )

    assert Corvid::AscFacility.applies?(vendor_id: "1234567890", on: Date.new(2024, 6, 1)),
           "NPI vendor_id must match the CCN-keyed ASC row via crosswalk"
  end

  test "applies? does not match when crosswalk row is outside the service date window" do
    Corvid::AscFacility.create!(
      ccn: "451301", effective_date: Date.new(2015, 1, 1)
    )
    Corvid::NpiCcnCrosswalk.create!(
      npi: "1234567890", ccn: "451301",
      effective_date: Date.new(2015, 1, 1), end_date: Date.new(2019, 12, 31)
    )

    refute Corvid::AscFacility.applies?(vendor_id: "1234567890", on: Date.new(2024, 6, 1)),
           "NPI billed under a different CCN by 2024, must not match expired crosswalk"
  end
end
