# frozen_string_literal: true

require "test_helper"

# Real OPPS APC rate provider (#277). Returns nil when CMS data isn't
# loaded for the (year, APC, locality) — the analyzer falls back to
# OppsStubRateProvider in that case.
class Corvid::OppsRateProviderTest < ActiveSupport::TestCase
  setup do
    @cy = 2026
    Corvid::OppsApcWeight.create!(
      calendar_year: @cy, apc_code: "5071", relative_weight: 25.4378
    )
    Corvid::OppsConversionFactor.create!(
      calendar_year: @cy, locality: "NATIONAL",
      conversion_factor: 89.169, wage_index: 1.0
    )
    Corvid::OppsConversionFactor.create!(
      calendar_year: @cy, locality: "01",
      conversion_factor: 89.169, wage_index: 1.085
    )
  end

  test "rate_for computes weight × CF × wage_index for known data" do
    # 25.4378 × 89.169 × 1.0 = 2267.99 (approx)
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    assert_in_delta 2_268.27, rate, 1.0
  end

  test "rate_for applies locality-specific wage index" do
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "01", date: Date.new(2026, 6, 15)
    )
    # 25.4378 × 89.169 × 1.085 = 2461.07 (approx)
    assert_in_delta 2_461.07, rate, 1.5
  end

  test "rate_for uses CALENDAR year — Jan 1 boundary, not Oct 1" do
    # A November 2026 service date stays in CY 2026 (vs IPPS which
    # would convert to FY 2027 for the same date).
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 11, 15)
    )
    refute_nil rate
  end

  test "rate_for falls back to NATIONAL locality when locality-specific row missing" do
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "99", date: Date.new(2026, 6, 15)
    )
    assert_in_delta 2_268.27, rate, 1.0,
                    "unknown locality should fall back to NATIONAL row"
  end

  test "rate_for returns nil when APC isn't loaded for that year" do
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "9999", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    assert_nil rate
  end

  test "rate_for returns nil when no conversion factor row exists" do
    Corvid::OppsConversionFactor.unscoped.delete_all
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    assert_nil rate
  end

  test "rate_for returns nil for missing inputs" do
    assert_nil Corvid::OppsRateProvider.rate_for(apc_code: nil, locality: "01", date: Date.current)
    assert_nil Corvid::OppsRateProvider.rate_for(apc_code: "5071", locality: "01", date: nil)
  end

  test "source returns :opps_real symbol to match the rate-provider contract" do
    assert_equal :opps_real, Corvid::OppsRateProvider.source
  end

  test "lookup_for returns rate + release_label so analyzer can downgrade stub-derived data" do
    Corvid::OppsApcWeight.unscoped.delete_all
    Corvid::OppsApcWeight.create!(
      calendar_year: @cy, apc_code: "5071", relative_weight: 25.4378,
      release_label: "stub_v1"
    )
    lookup = Corvid::OppsRateProvider.lookup_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    assert_equal "stub_v1", lookup.release_label,
                 "if either row is stub-labeled, the lookup propagates it"
  end
end
