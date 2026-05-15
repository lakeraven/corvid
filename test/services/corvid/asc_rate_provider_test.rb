# frozen_string_literal: true

require "test_helper"

# Real ASC HCPCS rate provider (#278). Returns nil when CMS data is not
# loaded for the (year, HCPCS, locality), letting the analyzer fall
# through to OPPS as the conservative outpatient default.
class Corvid::AscRateProviderTest < ActiveSupport::TestCase
  setup do
    @cy = 2026
    Corvid::AscHcpcsRate.create!(
      calendar_year: @cy,
      hcpcs_code: "0102T",
      payment_indicator: "G2",
      payment_weight: 29.2047
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: @cy,
      locality: "NATIONAL",
      conversion_factor: 56.322,
      wage_index: 1.0
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: @cy,
      locality: "01",
      conversion_factor: 56.322,
      wage_index: 1.085
    )
  end

  test "rate_for computes weight times conversion factor times wage index" do
    rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "NATIONAL",
      date: Date.new(2026, 6, 15)
    )
    assert_in_delta 1_644.87, rate, 0.01
  end

  test "rate_for applies locality-specific wage index" do
    rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "01",
      date: Date.new(2026, 6, 15)
    )
    assert_in_delta 1_784.68, rate, 0.01
  end

  test "rate_for uses calendar-year boundaries" do
    rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "NATIONAL",
      date: Date.new(2026, 11, 15)
    )
    refute_nil rate
  end

  test "rate_for falls back to NATIONAL locality when locality-specific row is missing" do
    rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "99",
      date: Date.new(2026, 6, 15)
    )
    assert_in_delta 1_644.87, rate, 0.01
  end

  test "rate_for normalizes nil and blank locality to NATIONAL" do
    [ nil, "", "   " ].each do |loc|
      rate = Corvid::AscRateProvider.rate_for(
        hcpcs_code: "0102T",
        locality: loc,
        date: Date.new(2026, 6, 15)
      )
      assert_in_delta 1_644.87, rate, 0.01
    end
  end

  test "rate_for returns nil when HCPCS is not loaded for that year" do
    assert_nil Corvid::AscRateProvider.rate_for(
      hcpcs_code: "9999T",
      locality: "NATIONAL",
      date: Date.new(2026, 6, 15)
    )
  end

  test "rate_for returns nil when no conversion factor row exists" do
    Corvid::AscConversionFactor.unscoped.delete_all
    assert_nil Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "NATIONAL",
      date: Date.new(2026, 6, 15)
    )
  end

  test "rate_for returns nil for missing inputs" do
    assert_nil Corvid::AscRateProvider.rate_for(hcpcs_code: nil, locality: "01", date: Date.current)
    assert_nil Corvid::AscRateProvider.rate_for(hcpcs_code: "0102T", locality: "01", date: nil)
  end

  test "source returns asc real symbol to match the rate-provider contract" do
    assert_equal :asc_real, Corvid::AscRateProvider.source
  end

  test "lookup_for propagates stub release label from either row" do
    Corvid::AscConversionFactor.unscoped.delete_all
    Corvid::AscConversionFactor.create!(
      calendar_year: @cy,
      locality: "NATIONAL",
      conversion_factor: 56.322,
      wage_index: 1.0,
      release_label: "stub_asc_cf"
    )

    lookup = Corvid::AscRateProvider.lookup_for(
      hcpcs_code: "0102T",
      locality: "NATIONAL",
      date: Date.new(2026, 6, 15)
    )
    assert_equal "stub_asc_cf", lookup.release_label
  end
end
