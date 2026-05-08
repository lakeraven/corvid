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

  test "year outside the table uses the default" do
    rate = Corvid::OppsStubRateProvider.rate_for(date: Date.new(2099, 1, 1))
    assert rate.is_a?(Numeric)
    assert rate.positive?
  end

  test "nil date returns nil" do
    assert_nil Corvid::OppsStubRateProvider.rate_for(date: nil)
  end

  test "source is :stub" do
    assert_equal :stub, Corvid::OppsStubRateProvider.source
  end
end
