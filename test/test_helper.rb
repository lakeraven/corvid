# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"
require "minitest/mock"

# Reset state between tests
module ActiveSupport
  class TestCase
    setup do
      Corvid::TenantContext.reset!
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    teardown do
      Corvid::TenantContext.reset!
    end

    private

    def with_tenant(identifier, &block)
      Corvid::TenantContext.with_tenant(identifier, &block)
    end
  end
end
