# frozen_string_literal: true

require "test_helper"

class Corvid::CahFacilityTest < ActiveSupport::TestCase
  test "NPI-only row is valid: CMS feeds may key by NPI rather than CCN" do
    row = Corvid::CahFacility.new(
      npi: "1234567890", effective_date: Date.new(2020, 1, 1)
    )
    assert row.valid?
    row.save!
    assert Corvid::CahFacility.applies?(vendor_id: "1234567890", on: Date.new(2021, 6, 1))
  end

  test "row missing both ccn and npi is rejected" do
    row = Corvid::CahFacility.new(effective_date: Date.new(2020, 1, 1))
    refute row.valid?
    assert_match(/at least one of ccn or npi/, row.errors.full_messages.join)
  end

  test "npi uniqueness scoped to effective_date prevents overlap on the NPI side" do
    Corvid::CahFacility.create!(
      npi: "1234567890", effective_date: Date.new(2020, 1, 1)
    )
    dup = Corvid::CahFacility.new(
      npi: "1234567890", effective_date: Date.new(2020, 1, 1)
    )
    refute dup.valid?,
           "same NPI at same effective_date must be rejected (symmetric with ccn)"
  end

  test "ccn is unique scoped to effective_date so historical periods coexist" do
    Corvid::CahFacility.create!(
      ccn: "451301", effective_date: Date.new(2015, 1, 1), end_date: Date.new(2018, 12, 31)
    )
    # Same CCN, different effective_date: allowed (facility lost then regained
    # CAH status, or CMS republished with a corrected effective date).
    later = Corvid::CahFacility.new(
      ccn: "451301", effective_date: Date.new(2020, 1, 1)
    )
    assert later.valid?, "second historical period for the same CCN must be allowed"
    later.save!

    # Same (ccn, effective_date) tuple: rejected.
    dup = Corvid::CahFacility.new(
      ccn: "451301", effective_date: Date.new(2015, 1, 1)
    )
    refute dup.valid?,
           "same CCN at the same effective_date must be rejected as a duplicate"
  end

  test "applies? returns the right answer per service date across historical periods" do
    Corvid::CahFacility.create!(
      ccn: "451301", effective_date: Date.new(2015, 1, 1), end_date: Date.new(2018, 12, 31)
    )
    Corvid::CahFacility.create!(
      ccn: "451301", effective_date: Date.new(2020, 1, 1)
    )

    assert Corvid::CahFacility.applies?(vendor_id: "451301", on: Date.new(2017, 6, 1)),
           "within first historical period"
    refute Corvid::CahFacility.applies?(vendor_id: "451301", on: Date.new(2019, 6, 1)),
           "gap between periods"
    assert Corvid::CahFacility.applies?(vendor_id: "451301", on: Date.new(2022, 6, 1)),
           "within second historical period"
  end
end
