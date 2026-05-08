# frozen_string_literal: true

require "test_helper"

class Corvid::IppsStubRateProviderTest < ActiveSupport::TestCase
  test "returns a positive rate for a known DRG and year" do
    rate = Corvid::IppsStubRateProvider.rate_for(
      drg_code: "470", date: Date.new(2024, 5, 1)
    )
    assert rate.is_a?(Numeric)
    assert rate.positive?
  end

  test "applies the DRG-specific multiplier" do
    # DRG 236 (CABG) is 2.75x national avg per the multiplier table;
    # DRG 287 (cardiac cath) is 0.65x. CABG should be materially higher.
    cabg = Corvid::IppsStubRateProvider.rate_for(drg_code: "236", date: Date.new(2024, 1, 1))
    cath = Corvid::IppsStubRateProvider.rate_for(drg_code: "287", date: Date.new(2024, 1, 1))
    assert cabg > cath * 3, "CABG should be much more expensive than diagnostic cath"
  end

  test "rate scales with year" do
    rate_2010 = Corvid::IppsStubRateProvider.rate_for(drg_code: "470", date: Date.new(2010, 1, 1))
    rate_2026 = Corvid::IppsStubRateProvider.rate_for(drg_code: "470", date: Date.new(2026, 1, 1))
    assert rate_2026 > rate_2010, "later year should have higher rate"
  end

  test "unknown DRG falls back to 1.0 multiplier (national average)" do
    rate = Corvid::IppsStubRateProvider.rate_for(drg_code: "9999", date: Date.new(2024, 1, 1))
    expected = Corvid::IppsStubRateProvider::NATIONAL_AVERAGE_BY_YEAR[2024]
    assert_equal expected.to_f, rate
  end

  test "year outside table uses default national average" do
    rate = Corvid::IppsStubRateProvider.rate_for(drg_code: "470", date: Date.new(2099, 1, 1))
    assert rate.is_a?(Numeric)
    assert rate.positive?
  end

  test "nil DRG returns nil" do
    assert_nil Corvid::IppsStubRateProvider.rate_for(drg_code: nil, date: Date.new(2024, 1, 1))
  end

  test "nil date returns nil" do
    assert_nil Corvid::IppsStubRateProvider.rate_for(drg_code: "470", date: nil)
  end

  test "source is :stub" do
    assert_equal :stub, Corvid::IppsStubRateProvider.source
  end
end
