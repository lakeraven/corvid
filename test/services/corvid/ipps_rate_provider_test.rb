# frozen_string_literal: true

require "test_helper"

# Real IPPS rate provider (#276). Returns nil when CMS data isn't loaded
# for the (year, DRG) or (year, locality) — the analyzer falls back to
# IppsStubRateProvider in that case so an obligation still gets a
# directional dollar figure at :stub_estimate confidence.
class Corvid::IppsRateProviderTest < ActiveSupport::TestCase
  setup do
    @fy = 2026
    Corvid::IppsDrgWeight.create!(
      fiscal_year: @fy, drg_code: "470", relative_weight: 2.0743
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: @fy, locality: "NATIONAL",
      base_rate: 6_500.0, wage_index: 1.0
    )
    Corvid::IppsHospitalRate.create!(
      fiscal_year: @fy, locality: "01",
      base_rate: 6_500.0, wage_index: 1.085 # Seattle-area wage index
    )
  end

  test "rate_for computes weight × base × wage_index for known data" do
    # 2.0743 × 6500 × 1.0 = 13_482.95
    rate = Corvid::IppsRateProvider.rate_for(
      drg_code: "470", locality: "NATIONAL", date: Date.new(2026, 1, 15)
    )
    assert_in_delta 13_482.95, rate, 0.01
  end

  test "rate_for applies locality-specific wage index" do
    # 2.0743 × 6500 × 1.085 = 14_628.998... → 14_629.00
    rate = Corvid::IppsRateProvider.rate_for(
      drg_code: "470", locality: "01", date: Date.new(2026, 1, 15)
    )
    assert_in_delta 14_629.00, rate, 0.01
  end

  test "rate_for converts service date to federal fiscal year before lookup" do
    # IPPS rates change Oct 1, not Jan 1. A 2025-11-15 service date bills
    # against FY 2026 rates.
    rate = Corvid::IppsRateProvider.rate_for(
      drg_code: "470", locality: "NATIONAL", date: Date.new(2025, 11, 15)
    )
    assert_in_delta 13_482.95, rate, 0.01
  end

  test "rate_for falls back to NATIONAL locality when locality-specific row missing" do
    rate = Corvid::IppsRateProvider.rate_for(
      drg_code: "470", locality: "99", date: Date.new(2026, 1, 15)
    )
    assert_in_delta 13_482.95, rate, 0.01,
                    "unknown locality should fall back to NATIONAL row"
  end

  test "rate_for returns nil when DRG isn't loaded for that year" do
    rate = Corvid::IppsRateProvider.rate_for(
      drg_code: "999", locality: "NATIONAL", date: Date.new(2026, 1, 15)
    )
    assert_nil rate, "missing DRG → nil → analyzer falls back to stub"
  end

  test "rate_for returns nil when no hospital rate row exists for the year" do
    Corvid::IppsHospitalRate.unscoped.delete_all
    rate = Corvid::IppsRateProvider.rate_for(
      drg_code: "470", locality: "NATIONAL", date: Date.new(2026, 1, 15)
    )
    assert_nil rate, "missing hospital rate → nil → analyzer falls back to stub"
  end

  test "rate_for returns nil for missing inputs" do
    assert_nil Corvid::IppsRateProvider.rate_for(drg_code: nil, locality: "01", date: Date.current)
    assert_nil Corvid::IppsRateProvider.rate_for(drg_code: "470", locality: "01", date: nil)
  end

  test "source returns :ipps_real symbol to match the rate-provider contract" do
    assert_equal :ipps_real, Corvid::IppsRateProvider.source
  end
  # release_label merge: the DRG weight is row A, the hospital rate is
  # row B. "" is truthy, so `a || b` keeps a blank A and drops a real B.
  # Assertions compare the raw label — never via .presence — so a blank
  # winner fails here instead of being normalized away.

  test "lookup_for returns the hospital rate label when the DRG weight label is blank" do
    relabel_ipps(weight: "", hospital: "cms_ipps_fy2026")
    assert_equal "cms_ipps_fy2026", ipps_release_label
  end

  test "lookup_for keeps the DRG weight label when the hospital rate label is blank" do
    relabel_ipps(weight: "cms_ipps_fy2026", hospital: "")
    assert_equal "cms_ipps_fy2026", ipps_release_label
  end

  test "lookup_for returns nil when both IPPS release labels are blank" do
    # Nil, not "". The current `||` returns "" because "" is truthy, and
    # that empty string is what the analyzer then drops. A merge that
    # skips blank labels has nothing left to return, so the contract is nil.
    # Asserting "" would pass against the defect.
    relabel_ipps(weight: "", hospital: "")
    assert_nil ipps_release_label
  end

  test "lookup_for lets a stub label on either IPPS row win over a real label" do
    relabel_ipps(weight: "stub_drg_v1", hospital: "cms_ipps_fy2026")
    assert_equal "stub_drg_v1", ipps_release_label

    relabel_ipps(weight: "cms_ipps_fy2026", hospital: "stub_hospital_v1")
    assert_equal "stub_hospital_v1", ipps_release_label
  end

  test "lookup_for treats a whitespace-only IPPS label as blank" do
    relabel_ipps(weight: "   ", hospital: "cms_ipps_fy2026")
    assert_equal "cms_ipps_fy2026", ipps_release_label

    relabel_ipps(weight: "cms_ipps_fy2026", hospital: "   ")
    assert_equal "cms_ipps_fy2026", ipps_release_label

    relabel_ipps(weight: "   ", hospital: "   ")
    assert_nil ipps_release_label
  end

  private

  def relabel_ipps(weight:, hospital:)
    Corvid::IppsDrgWeight.find_by!(fiscal_year: @fy, drg_code: "470")
                         .update!(release_label: weight)
    Corvid::IppsHospitalRate.find_by!(fiscal_year: @fy, locality: "NATIONAL")
                            .update!(release_label: hospital)
  end

  def ipps_release_label
    Corvid::IppsRateProvider.lookup_for(
      drg_code: "470", locality: "NATIONAL", date: Date.new(2026, 1, 15)
    ).release_label
  end
end
