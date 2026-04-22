# frozen_string_literal: true

require "test_helper"

class Corvid::PriorAuthorizationServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_pa_test"

  test "service class exists and is callable" do
    with_tenant(TENANT) do
      assert defined?(Corvid::PriorAuthorizationService)
    end
  end
end
