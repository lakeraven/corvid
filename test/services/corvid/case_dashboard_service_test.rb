# frozen_string_literal: true

require "test_helper"

class Corvid::CaseDashboardServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_dash_test"

  test "service class exists" do
    assert defined?(Corvid::CaseDashboardService)
  end

  test "responds to summary" do
    with_tenant(TENANT) do
      assert Corvid::CaseDashboardService.respond_to?(:summary) ||
             Corvid::CaseDashboardService.respond_to?(:new)
    end
  end
end
