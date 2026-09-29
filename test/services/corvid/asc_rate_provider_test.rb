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
      calendar_year: @cy, locality: "NATIONAL", conversion_factor: 56.322
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

  test "rate_for applies CBSA-coded locality and falls back to NATIONAL for unknown CBSA" do
    # The locality column is a free-form string, so 5-digit CMS CBSA codes
    # work the same as 2-digit PFS locality codes. Wage index for the CBSA
    # comes from IppsHospitalRate (#369) — the CF row is NATIONAL-only,
    # matching the real-world CF (which doesn't vary by CBSA; only the
    # wage index does).
    Corvid::AscHcpcsRate.unscoped.delete_all
    Corvid::AscConversionFactor.unscoped.delete_all
    Corvid::IppsHospitalRate.unscoped.delete_all
    Corvid::AscHcpcsRate.create!(
      calendar_year: 2026,
      hcpcs_code: "0102T",
      payment_indicator: "G2",
      payment_weight: 29.2047
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: 2026, locality: "NATIONAL", conversion_factor: 56.322
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 1.0
    )
    # CBSA 10180 = Abilene, TX (real CMS Core-Based Statistical Area)
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: "10180", base_rate: 6_752.61, wage_index: 0.92
    )

    cbsa_rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "10180", date: Date.new(2026, 6, 15)
    )
    unknown_cbsa_rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "99999", date: Date.new(2026, 6, 15)
    )

    # 29.2047 × 56.322 × 0.92 = 1513.28
    assert_in_delta 1_513.28, cbsa_rate, 0.01
    # Unknown CBSA falls back to NATIONAL: 29.2047 × 56.322 × 1.0 = 1644.87
    assert_in_delta 1_644.87, unknown_cbsa_rate, 0.01
  end

  test "changing the IPPS wage index for a CBSA changes the ASC rate for that CBSA (#369)" do
    Corvid::IppsHospitalRate.create!(
      fiscal_year: @cy, locality: "31084", base_rate: 6_752.61, wage_index: 1.2463
    )
    low = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "31084", date: Date.new(2026, 6, 15)
    )

    Corvid::IppsHospitalRate.find_by(fiscal_year: @cy, locality: "31084").update!(wage_index: 1.5)
    high = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "31084", date: Date.new(2026, 6, 15)
    )

    refute_in_delta low, high, 0.01,
                    "updating the shared IPPS wage index for a CBSA should move the ASC rate for that CBSA"
  end

  test "rate_for falls back to wage_index 1.0 when no IPPS hospital rate is loaded at all" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    # 29.2047 × 56.322 × 1.0 = 1644.87
    assert_in_delta 1_644.87, rate, 0.01
  end

  test "rate_for uses CALENDAR year — Jan 1 boundary, not Oct 1" do
    # A November 2026 service date stays in CY 2026 (vs IPPS which
    # would convert to FY 2027 for the same date).
    rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "NATIONAL",
      date: Date.new(2026, 11, 15)
    )
    refute_nil rate
  end

  test "rate_for switches rate rows at the Jan 1 boundary across calendar years" do
    Corvid::AscHcpcsRate.unscoped.delete_all
    Corvid::AscConversionFactor.unscoped.delete_all
    Corvid::AscHcpcsRate.create!(
      calendar_year: 2026, hcpcs_code: "0102T", payment_weight: 20.0
    )
    Corvid::AscHcpcsRate.create!(
      calendar_year: 2027, hcpcs_code: "0102T", payment_weight: 30.0
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: 2026, locality: "NATIONAL",
      conversion_factor: 50.0, wage_index: 1.0
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: 2027, locality: "NATIONAL",
      conversion_factor: 60.0, wage_index: 1.0
    )

    dec_31 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 12, 31)
    )
    jan_1 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2027, 1, 1)
    )

    assert_in_delta 1_000.0, dec_31, 0.01, "Dec 31, 2026 should price against CY 2026 rows"
    assert_in_delta 1_800.0, jan_1,  0.01, "Jan 1, 2027 should price against CY 2027 rows"
  end

  test "wage index tracks the federal fiscal year, independent of the ASC calendar-year price switch" do
    # The ASC weight/CF table switches on the CY boundary (Jan 1); the
    # IPPS-sourced wage index switches on the FY boundary (Oct 1) —
    # different calendars, per #369's design. Dec 31 2026 and Jan 1
    # 2027 both fall in FY 2027 (which started Oct 1 2026), so they
    # share the same wage index even though they price against
    # different CY weight/CF rows.
    Corvid::AscHcpcsRate.unscoped.delete_all
    Corvid::AscConversionFactor.unscoped.delete_all
    Corvid::IppsHospitalRate.unscoped.delete_all

    Corvid::AscHcpcsRate.create!(
      calendar_year: 2026, hcpcs_code: "0102T", payment_weight: 20.0
    )
    Corvid::AscHcpcsRate.create!(
      calendar_year: 2027, hcpcs_code: "0102T", payment_weight: 30.0
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: 2026, locality: "NATIONAL", conversion_factor: 50.0
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: 2027, locality: "NATIONAL", conversion_factor: 60.0
    )
    # FY 2027 (Oct 2026 – Sep 2027) wage index for locality "01" covers
    # both Dec 31, 2026 and Jan 1, 2027 service dates.
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2027, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 1.0
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2027, locality: "01", base_rate: 6_752.61, wage_index: 1.085
    )

    dec_31_locality_01 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "01", date: Date.new(2026, 12, 31)
    )
    jan_1_locality_01 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "01", date: Date.new(2027, 1, 1)
    )

    # Dec 31, 2026: CY 2026 weight/CF (20.0 × 50.0) × FY 2027 wage index (1.085) = 1085.00
    assert_in_delta 1_085.0, dec_31_locality_01, 0.01
    # Jan 1, 2027: CY 2027 weight/CF (30.0 × 60.0) × same FY 2027 wage index (1.085) = 1953.00
    assert_in_delta 1_953.0, jan_1_locality_01, 0.01

    refute_in_delta dec_31_locality_01, jan_1_locality_01, 0.01,
                    "Jan 1 switches the CY weight/CF table even though the FY wage index doesn't turn over until Oct 1"
  end

  test "rate_for returns nil on Jan 1 when next calendar year rows are missing" do
    Corvid::AscHcpcsRate.unscoped.delete_all
    Corvid::AscConversionFactor.unscoped.delete_all
    Corvid::AscHcpcsRate.create!(
      calendar_year: 2026, hcpcs_code: "0102T", payment_weight: 20.0
    )
    Corvid::AscConversionFactor.create!(
      calendar_year: 2026, locality: "NATIONAL",
      conversion_factor: 50.0, wage_index: 1.0
    )

    dec_31 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 12, 31)
    )
    jan_1 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2027, 1, 1)
    )

    assert_in_delta 1_000.0, dec_31, 0.01, "Dec 31, 2026 should price against CY 2026 rows"
    assert_nil jan_1, "Jan 1, 2027 should return nil when CY 2027 ASC rows are missing"
  end

  test "rate_for keeps Sep 30 and Oct 1 in the same calendar year (not fiscal)" do
    sep_30 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "NATIONAL",
      date: Date.new(2026, 9, 30)
    )
    oct_1 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "NATIONAL",
      date: Date.new(2026, 10, 1)
    )

    refute_nil sep_30
    refute_nil oct_1
    assert_in_delta sep_30, oct_1, 0.001,
                    "Sep 30 and Oct 1 in same CY should hit identical CY 2026 rows"
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
