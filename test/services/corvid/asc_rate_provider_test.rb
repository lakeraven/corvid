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
    seed_asc_labor_share(calendar_year: @cy)
  end

  test "rate_for computes weight times conversion factor times labor-adjusted wage factor" do
    rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "NATIONAL",
      date: Date.new(2026, 6, 15)
    )
    expected = asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 1.0
    )
    assert_equal expected, rate
  end

  test "rate_for applies locality-specific wage index through labor share" do
    rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T",
      locality: "01",
      date: Date.new(2026, 6, 15)
    )
    expected = asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 1.085
    )
    assert_equal expected, rate
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
    seed_asc_labor_share(calendar_year: 2026)

    cbsa_rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "10180", date: Date.new(2026, 6, 15)
    )
    unknown_cbsa_rate = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "99999", date: Date.new(2026, 6, 15)
    )

    assert_equal asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 0.92
    ), cbsa_rate
    assert_equal asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 1.0
    ), unknown_cbsa_rate
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
    expected = asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 1.0
    )
    assert_equal expected, rate
  end

  test "lookup_for leaves wage_index_fiscal_year nil when defaulting wage index to 1.0 with no IPPS row (#722)" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    lookup = Corvid::AscRateProvider.lookup_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    refute_nil lookup
    assert_nil lookup.wage_index_fiscal_year,
               "no FY wage-index row was used; default 1.0 must not invent an FY"
  end

  test "January CY 2026 service maps calendar year to FY 2026 wage index (#722)" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 1.12
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2025, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 0.80
    )

    lookup = Corvid::AscRateProvider.lookup_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 1, 15)
    )
    expected = asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 1.12
    )

    assert_equal expected, lookup.rate
    assert_equal 2026, lookup.wage_index_fiscal_year
    assert_equal ASC_LABOR_SHARE, lookup.labor_share
  end

  test "Oct-Dec CY 2026 service uses FY 2026 wage index not FY 2027 (#722)" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 1.10
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2027, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 2.00
    )

    lookup = Corvid::AscRateProvider.lookup_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 11, 15)
    )
    expected = asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 1.10
    )

    assert_equal expected, lookup.rate
    assert_equal 2026, lookup.wage_index_fiscal_year
  end

  test "lookup_for returns nil when no labor share row exists for the calendar year" do
    Corvid::CmsLaborShare.unscoped.delete_all
    assert_nil Corvid::AscRateProvider.lookup_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
  end

  test "rate_for uses CALENDAR year for ASC weight and CF — Jan 1 boundary, not Oct 1" do
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
    seed_asc_labor_share(calendar_year: 2026)
    seed_asc_labor_share(calendar_year: 2027)

    dec_31 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 12, 31)
    )
    jan_1 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2027, 1, 1)
    )

    assert_in_delta 1_000.0, dec_31, 0.01, "Dec 31, 2026 should price against CY 2026 rows"
    assert_in_delta 1_800.0, jan_1,  0.01, "Jan 1, 2027 should price against CY 2027 rows"
  end

  test "CY N service maps to FY N wage index while ASC weight and CF stay calendar-year keyed (#722)" do
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
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 1.0
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: "01", base_rate: 6_752.61, wage_index: 1.085
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2027, locality: "01", base_rate: 6_752.61, wage_index: 1.200
    )
    seed_asc_labor_share(calendar_year: 2026)
    seed_asc_labor_share(calendar_year: 2027)

    dec_31_locality_01 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "01", date: Date.new(2026, 12, 31)
    )
    jan_1_locality_01 = Corvid::AscRateProvider.rate_for(
      hcpcs_code: "0102T", locality: "01", date: Date.new(2027, 1, 1)
    )

    assert_equal asc_labor_adjusted_rate(
      weight: 20.0, conversion_factor: 50.0, wage_index: 1.085
    ), dec_31_locality_01
    assert_equal asc_labor_adjusted_rate(
      weight: 30.0, conversion_factor: 60.0, wage_index: 1.200
    ), jan_1_locality_01

    refute_equal dec_31_locality_01, jan_1_locality_01
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
    seed_asc_labor_share(calendar_year: 2026)

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
    assert_in_delta asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 1.0
    ), rate, 0.01
  end

  test "rate_for normalizes nil and blank locality to NATIONAL" do
    [ nil, "", "   " ].each do |loc|
      rate = Corvid::AscRateProvider.rate_for(
        hcpcs_code: "0102T",
        locality: loc,
        date: Date.new(2026, 6, 15)
      )
      assert_in_delta asc_labor_adjusted_rate(
      weight: 29.2047, conversion_factor: 56.322, wage_index: 1.0
    ), rate, 0.01
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
  # release_label merge: the HCPCS rate is row A, the conversion factor
  # is row B. Assertions compare the raw label, never via .presence.

  test "lookup_for returns the conversion-factor label when the HCPCS rate label is blank" do
    relabel_asc(hcpcs: "", factor: "cms_asc_cy2026")
    assert_equal "cms_asc_cy2026", asc_release_label
  end

  test "lookup_for keeps the HCPCS rate label when the conversion-factor label is blank" do
    relabel_asc(hcpcs: "cms_asc_cy2026", factor: "")
    assert_equal "cms_asc_cy2026", asc_release_label
  end

  test "lookup_for returns nil when both ASC release labels are blank" do
    # Nil, not "". "" is truthy, so the pre-fix `||` returned "" — the
    # defect. Once blank labels are skipped, neither row contributes a
    # label and the lookup must return nil. Asserting "" passed before the fix.
    relabel_asc(hcpcs: "", factor: "")
    assert_nil asc_release_label
  end

  test "lookup_for lets a stub label on either ASC row win over a real label" do
    relabel_asc(hcpcs: "stub_hcpcs_v1", factor: "cms_asc_cy2026")
    assert_equal "stub_hcpcs_v1", asc_release_label

    relabel_asc(hcpcs: "cms_asc_cy2026", factor: "stub_cf_v1")
    assert_equal "stub_cf_v1", asc_release_label
  end

  test "lookup_for treats a whitespace-only ASC label as blank" do
    relabel_asc(hcpcs: "   ", factor: "cms_asc_cy2026")
    assert_equal "cms_asc_cy2026", asc_release_label

    relabel_asc(hcpcs: "cms_asc_cy2026", factor: "   ")
    assert_equal "cms_asc_cy2026", asc_release_label

    relabel_asc(hcpcs: "   ", factor: "   ")
    assert_nil asc_release_label
  end

  private

  def relabel_asc(hcpcs:, factor:)
    Corvid::AscHcpcsRate.find_by!(calendar_year: @cy, hcpcs_code: "0102T")
                        .update!(release_label: hcpcs)
    Corvid::AscConversionFactor.find_by!(calendar_year: @cy, locality: "NATIONAL")
                               .update!(release_label: factor)
  end

  def asc_release_label
    Corvid::AscRateProvider.lookup_for(
      hcpcs_code: "0102T", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    ).release_label
  end
end
