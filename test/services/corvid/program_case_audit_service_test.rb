# frozen_string_literal: true

require "test_helper"

class Corvid::ProgramCaseAuditServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_audit_test"

  test "service class exists" do
    assert defined?(Corvid::ProgramCaseAuditService)
  end
end
