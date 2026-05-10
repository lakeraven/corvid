# frozen_string_literal: true

require "test_helper"

class Corvid::OppsStubRateProviderTest < ActiveSupport::TestCase
  test "returns a positive rate for a known year" do
    rate = Corvid::OppsStubRateProvider.rate_for(date: Date.new(2024, 5, 1))
    assert rate.is_a?(Numeric)
    assert rate.positive?
  end

  test "rate scales with year" do
    rate_2010 = Corvid::OppsStubRateProvider.rate_for(date: Date.new(2010, 1, 1))
    rate_2026 = Corvid::OppsStubRateProvider.rate_for(date: Date.new(2026, 1, 1))
    assert rate_2026 > rate_2010
  end

  test "year outside the table returns nil" do
    # Returning nil (rather than a fabricated default) lets the analyzer's
    # stub-fallback path route the obligation to :no_rate_for_year for
    # service dates the stub has no opinion on. Previously the stub
    # returned a default national-average which silently flagged
    # those obligations as :stub_estimate — misrepresenting confidence.
    assert_nil Corvid::OppsStubRateProvider.rate_for(date: Date.new(2099, 1, 1))
    assert_nil Corvid::OppsStubRateProvider.rate_for(date: Date.new(1995, 1, 1))
  end

  test "nil date returns nil" do
    assert_nil Corvid::OppsStubRateProvider.rate_for(date: nil)
  end

  test "source is :stub" do
    assert_equal :stub, Corvid::OppsStubRateProvider.source
  end
end
