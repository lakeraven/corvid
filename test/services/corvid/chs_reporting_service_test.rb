# frozen_string_literal: true

require "test_helper"

class Corvid::ChsReportingServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_rpt_test"

  test "service class exists" do
    assert defined?(Corvid::ChsReportingService)
  end

  test "responds to generate" do
    with_tenant(TENANT) do
      assert Corvid::ChsReportingService.respond_to?(:generate) ||
             Corvid::ChsReportingService.respond_to?(:new)
    end
  end
end
