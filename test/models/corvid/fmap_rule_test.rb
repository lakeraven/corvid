# frozen_string_literal: true

require "test_helper"

module Corvid
  class FmapRuleTest < ActiveSupport::TestCase
    test "loader seeds the default rule set idempotently" do
      count = FmapRuleLoader.load_defaults!
      assert_equal count, FmapRuleLoader.load_defaults!
      assert_equal count, FmapRule.count
      assert FmapRule.exists?(rule_key: "us-arpa-9815-uio-100")
    end

    test "in_force_on applies effective and expiration dates" do
      FmapRuleLoader.load_defaults!

      arpa = FmapRule.find_by!(rule_key: "us-arpa-9815-uio-100")
      assert_includes FmapRule.in_force_on(Date.new(2022, 6, 1)), arpa
      refute_includes FmapRule.in_force_on(Date.new(2024, 6, 1)), arpa
      refute_includes FmapRule.in_force_on(Date.new(2021, 3, 31)), arpa
    end

    test "dormant rules are never in force" do
      FmapRuleLoader.load_defaults!

      parity = FmapRule.find_by!(rule_key: "us-uio-parity-100")
      assert parity.dormant?
      refute_includes FmapRule.in_force_on(Date.current), parity
      assert_includes FmapRule.dormant, parity
    end

    test "expires_on before effective_on is rejected" do
      rule = FmapRule.new(
        rule_key: "test-bad-window",
        jurisdiction: "US",
        category: "fmap_regular",
        statutory_citation: "test",
        effective_on: Date.new(2023, 1, 1),
        expires_on: Date.new(2022, 1, 1)
      )
      refute rule.valid?
      assert rule.errors[:expires_on].any?
    end
  end
end
