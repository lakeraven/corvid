# frozen_string_literal: true

require "test_helper"
require "corvid/rules_engine"

class Corvid::RulesEngineTest < ActiveSupport::TestCase
  class TestRuleset
    def is_valid(is_active, has_permission)
      is_active && has_permission
    end

    def is_active(status)
      status == "active"
    end

    def has_permission(role)
      %w[admin user].include?(role)
    end

    def standalone_rule
      true
    end
  end

  setup do
    @engine = Corvid::RulesEngine.new(TestRuleset.new)
  end

  test "evaluates input facts directly" do
    @engine.set_facts(status: "active")
    result = @engine.evaluate(:status)

    assert_instance_of Corvid::RulesEngine::Input, result
    assert_equal :status, result.name
    assert_equal "active", result.value
    assert_empty result.reasons
  end

  test "evaluates computed facts from rules" do
    @engine.set_facts(status: "active")
    result = @engine.evaluate(:is_active)

    assert_instance_of Corvid::RulesEngine::Fact, result
    assert result.value
  end

  test "evaluates computed facts with false result" do
    @engine.set_facts(status: "inactive")
    result = @engine.evaluate(:is_active)

    assert_equal false, result.value
  end

  test "evaluates rules with no dependencies" do
    result = @engine.evaluate(:standalone_rule)

    assert_instance_of Corvid::RulesEngine::Fact, result
    assert result.value
  end

  test "automatically evaluates dependencies" do
    @engine.set_facts(status: "active", role: "admin")
    result = @engine.evaluate(:is_valid)

    assert result.value
    assert_equal 2, result.reasons.length
    assert_includes result.reasons.map(&:name), :is_active
    assert_includes result.reasons.map(&:name), :has_permission
  end

  test "propagates false from dependencies" do
    @engine.set_facts(status: "inactive", role: "admin")
    result = @engine.evaluate(:is_valid)

    assert_equal false, result.value
    is_active = result.reasons.find { |r| r.name == :is_active }
    has_permission = result.reasons.find { |r| r.name == :has_permission }
    assert_equal false, is_active.value
    assert has_permission.value
  end

  test "tracks dependency chain in reasons" do
    @engine.set_facts(status: "active", role: "admin")
    result = @engine.evaluate(:is_valid)

    is_active = result.reasons.find { |r| r.name == :is_active }
    has_permission = result.reasons.find { |r| r.name == :has_permission }

    assert_equal 1, is_active.reasons.length
    assert_equal :status, is_active.reasons.first.name
    assert_equal 1, has_permission.reasons.length
    assert_equal :role, has_permission.reasons.first.name
  end

  test "caches evaluated facts" do
    @engine.set_facts(status: "active")
    result1 = @engine.evaluate(:is_active)
    result2 = @engine.evaluate(:is_active)

    assert_same result1, result2
  end

  test "returns nil value for undefined rules" do
    result = @engine.evaluate(:nonexistent_rule)

    assert_nil result.value
    assert_empty result.reasons
  end

  test "handles nil input values" do
    @engine.set_facts(status: nil)
    result = @engine.evaluate(:is_active)

    assert_equal false, result.value
  end

  test "reset clears all cached facts" do
    @engine.set_facts(status: "active")
    @engine.evaluate(:is_active)

    @engine.reset!
    @engine.set_facts(status: "inactive")
    result = @engine.evaluate(:is_active)

    assert_equal false, result.value
  end

  test "all_facts returns complete dependency tree" do
    @engine.set_facts(status: "active", role: "admin")
    result = @engine.evaluate(:is_valid)
    all_facts = result.all_facts

    fact_names = all_facts.map(&:name)
    assert_includes fact_names, :is_valid
    assert_includes fact_names, :is_active
    assert_includes fact_names, :has_permission
    assert_includes fact_names, :status
    assert_includes fact_names, :role
  end

  test "failed_facts returns only false facts" do
    @engine.set_facts(status: "inactive", role: "guest")
    result = @engine.evaluate(:is_valid)
    failed = result.failed_facts

    failed_names = failed.map(&:name)
    assert_includes failed_names, :is_valid
    assert_includes failed_names, :is_active
    assert_includes failed_names, :has_permission
  end

  test "failed_facts returns empty for all passing" do
    @engine.set_facts(status: "active", role: "admin")
    result = @engine.evaluate(:is_valid)

    assert_empty result.failed_facts
  end

  test "fact has meaningful to_s" do
    @engine.set_facts(status: "active")
    result = @engine.evaluate(:is_active)

    assert_equal "Fact(is_active: true)", result.to_s
  end

  test "fact has meaningful inspect" do
    @engine.set_facts(status: "active")
    result = @engine.evaluate(:is_active)

    assert_includes result.inspect, "is_active"
    assert_includes result.inspect, "true"
    assert_includes result.inspect, "status"
  end
end
