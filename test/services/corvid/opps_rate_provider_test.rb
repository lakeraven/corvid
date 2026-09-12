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
      calendar_year: @cy, locality: "NATIONAL", conversion_factor: 89.169
    )
    # Wage index is sourced from IppsHospitalRate, not from the CF row
    # itself (#369) — the CF row's wage_index column is unread by the
    # rate provider (still present in schema; dropped in the #370
    # follow-up migration).
    Corvid::IppsHospitalRate.create!(
      fiscal_year: @cy, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 1.0
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: @cy, locality: "01", base_rate: 6_752.61, wage_index: 1.085
    )
  end

  test "rate_for computes weight × CF × wage_index for known data" do
    # 25.4378 × 89.169 × 1.0 = 2268.2622 → 2268.26
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    assert_in_delta 2_268.26, rate, 0.01
  end

  test "rate_for applies locality-specific wage index" do
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "01", date: Date.new(2026, 6, 15)
    )
    # 25.4378 × 89.169 × 1.085 = 2461.06448695 → 2461.06 (std round)
    assert_in_delta 2_461.06, rate, 0.01
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

  test "rate_for normalizes nil/blank locality to NATIONAL" do
    [ nil, "", "   " ].each do |loc|
      rate = Corvid::OppsRateProvider.rate_for(
        apc_code: "5071", locality: loc, date: Date.new(2026, 6, 15)
      )
      assert_in_delta 2_268.26, rate, 0.01,
                      "locality=#{loc.inspect} should fall back to NATIONAL"
    end
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

  test "lookup_for propagates a stub label carried only by the IPPS wage index row" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    Corvid::IppsHospitalRate.create!(
      fiscal_year: @cy, locality: "NATIONAL", base_rate: 6_752.61,
      wage_index: 1.0, release_label: "stub_v1"
    )
    lookup = Corvid::OppsRateProvider.lookup_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    assert_equal "stub_v1", lookup.release_label,
                 "a stub-derived wage index row downgrades the combined result too"
  end

  test "changing the IPPS wage index for a CBSA changes the OPPS rate for that CBSA (#369)" do
    Corvid::IppsHospitalRate.create!(
      fiscal_year: @cy, locality: "31084", base_rate: 6_752.61, wage_index: 1.2463
    )
    low = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "31084", date: Date.new(2026, 6, 15)
    )

    Corvid::IppsHospitalRate.find_by(fiscal_year: @cy, locality: "31084").update!(wage_index: 1.5)
    high = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "31084", date: Date.new(2026, 6, 15)
    )

    refute_in_delta low, high, 0.01,
                    "updating the shared IPPS wage index for a CBSA should move the OPPS rate for that CBSA"
  end

  test "rate_for falls back to wage_index 1.0 when no IPPS hospital rate is loaded at all" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    # 25.4378 × 89.169 × 1.0 = 2268.26
    assert_in_delta 2_268.26, rate, 0.01
  end
end
