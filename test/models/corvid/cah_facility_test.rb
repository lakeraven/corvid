# frozen_string_literal: true

require "test_helper"

class Corvid::CahFacilityTest < ActiveSupport::TestCase
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
