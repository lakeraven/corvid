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
    seed_opps_labor_share(calendar_year: @cy)
  end

  test "rate_for computes weight × CF × labor-adjusted wage factor for known data" do
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    expected = opps_labor_adjusted_rate(
      weight: 25.4378, conversion_factor: 89.169, wage_index: 1.0
    )
    assert_equal expected, rate
  end

  test "rate_for applies locality-specific wage index through labor share" do
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "01", date: Date.new(2026, 6, 15)
    )
    expected = opps_labor_adjusted_rate(
      weight: 25.4378, conversion_factor: 89.169, wage_index: 1.085
    )
    assert_equal expected, rate
  end

  test "Oct-Dec CY 2026 service uses FY 2026 wage index not FY 2027 (#722)" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2026, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 1.10
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: 2027, locality: "NATIONAL", base_rate: 6_752.61, wage_index: 2.00
    )

    lookup = Corvid::OppsRateProvider.lookup_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 11, 15)
    )
    expected = opps_labor_adjusted_rate(
      weight: 25.4378, conversion_factor: 89.169, wage_index: 1.10
    )
    wrong_fy = opps_labor_adjusted_rate(
      weight: 25.4378, conversion_factor: 89.169, wage_index: 2.00
    )

    assert_equal expected, lookup.rate
    refute_equal wrong_fy, lookup.rate
    assert_equal 2026, lookup.wage_index_fiscal_year
    assert_equal OPPS_LABOR_SHARE, lookup.labor_share
  end

  test "lookup_for prices with labor share read from the loaded row not a hardcoded constant (#722)" do
    share = BigDecimal("0.6200")
    Corvid::CmsLaborShare.unscoped.delete_all
    seed_opps_labor_share(calendar_year: @cy, labor_share: share)

    lookup = Corvid::OppsRateProvider.lookup_for(
      apc_code: "5071", locality: "01", date: Date.new(2026, 6, 15)
    )
    expected = opps_labor_adjusted_rate(
      weight: 25.4378, conversion_factor: 89.169, wage_index: 1.085, labor_share: share
    )

    assert_equal expected, lookup.rate
    assert_equal share, lookup.labor_share
  end

  test "lookup_for returns nil when no labor share row exists for the calendar year" do
    Corvid::CmsLaborShare.unscoped.delete_all
    lookup = Corvid::OppsRateProvider.lookup_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    assert_nil lookup,
               "missing labor share must not price silently at 100% labor share"
  end

  test "rate_for falls back to NATIONAL locality when locality-specific row missing" do
    rate = Corvid::OppsRateProvider.rate_for(
      apc_code: "5071", locality: "99", date: Date.new(2026, 6, 15)
    )
    expected = opps_labor_adjusted_rate(
      weight: 25.4378, conversion_factor: 89.169, wage_index: 1.0
    )
    assert_in_delta expected, rate, 0.01,
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
      assert_in_delta opps_labor_adjusted_rate(
        weight: 25.4378, conversion_factor: 89.169, wage_index: 1.0
      ), rate, 0.01,
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
    expected = opps_labor_adjusted_rate(
      weight: 25.4378, conversion_factor: 89.169, wage_index: 1.0
    )
    assert_equal expected, rate
  end

  test "lookup_for leaves wage_index_fiscal_year nil when defaulting wage index to 1.0 with no IPPS row (#722)" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    lookup = Corvid::OppsRateProvider.lookup_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    )
    refute_nil lookup
    assert_nil lookup.wage_index_fiscal_year,
               "no FY wage-index row was used; default 1.0 must not invent an FY"
  end

  # release_label merge: the APC weight is row A, the conversion factor
  # is row B. Assertions compare the raw label, never via .presence.

  test "lookup_for returns the conversion-factor label when the APC weight label is blank" do
    relabel_opps(weight: "", factor: "cms_opps_cy2026")
    assert_equal "cms_opps_cy2026", opps_release_label
  end

  test "lookup_for keeps the APC weight label when the conversion-factor label is blank" do
    relabel_opps(weight: "cms_opps_cy2026", factor: "")
    assert_equal "cms_opps_cy2026", opps_release_label
  end

  test "lookup_for returns nil when both OPPS release labels are blank" do
    # Nil, not "". "" is truthy, so the pre-fix `||` returned "" — the
    # defect. Once blank labels are skipped, neither row contributes a
    # label and the lookup must return nil. Asserting "" passed before the fix.
    relabel_opps(weight: "", factor: "")
    assert_nil opps_release_label
  end

  test "lookup_for lets a stub label on either OPPS row win over a real label" do
    relabel_opps(weight: "stub_apc_v1", factor: "cms_opps_cy2026")
    assert_equal "stub_apc_v1", opps_release_label

    relabel_opps(weight: "cms_opps_cy2026", factor: "stub_cf_v1")
    assert_equal "stub_cf_v1", opps_release_label
  end

  test "lookup_for treats a whitespace-only OPPS label as blank" do
    relabel_opps(weight: "   ", factor: "cms_opps_cy2026")
    assert_equal "cms_opps_cy2026", opps_release_label

    relabel_opps(weight: "cms_opps_cy2026", factor: "   ")
    assert_equal "cms_opps_cy2026", opps_release_label

    relabel_opps(weight: "   ", factor: "   ")
    assert_nil opps_release_label
  end

  private

  def relabel_opps(weight:, factor:)
    Corvid::OppsApcWeight.find_by!(calendar_year: @cy, apc_code: "5071")
                         .update!(release_label: weight)
    Corvid::OppsConversionFactor.find_by!(calendar_year: @cy, locality: "NATIONAL")
                                .update!(release_label: factor)
  end

  def opps_release_label
    Corvid::OppsRateProvider.lookup_for(
      apc_code: "5071", locality: "NATIONAL", date: Date.new(2026, 6, 15)
    ).release_label
  end
end
