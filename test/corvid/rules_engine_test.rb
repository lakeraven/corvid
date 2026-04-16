# frozen_string_literal: true

require "minitest/autorun"
require "corvid/rules_engine"

class Corvid::RulesEngineTest < Minitest::Test
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

  def setup
    @engine = Corvid::RulesEngine.new(TestRuleset.new)
  end

  def test_evaluates_input_facts_directly
    @engine.set_facts(status: "active")
    result = @engine.evaluate(:status)

    assert_instance_of Corvid::RulesEngine::Input, result
    assert_equal :status, result.name
    assert_equal "active", result.value
    assert_empty result.reasons
  end

  def test_evaluates_computed_facts_from_rules
    @engine.set_facts(status: "active")
    result = @engine.evaluate(:is_active)

    assert_instance_of Corvid::RulesEngine::Fact, result
    assert result.value
  end

  def test_evaluates_computed_facts_with_false_result
    @engine.set_facts(status: "inactive")
    assert_equal false, @engine.evaluate(:is_active).value
  end

  def test_evaluates_rules_with_no_dependencies
    result = @engine.evaluate(:standalone_rule)
    assert_instance_of Corvid::RulesEngine::Fact, result
    assert result.value
  end

  def test_automatically_evaluates_dependencies
    @engine.set_facts(status: "active", role: "admin")
    result = @engine.evaluate(:is_valid)

    assert result.value
    assert_equal 2, result.reasons.length
    assert_includes result.reasons.map(&:name), :is_active
    assert_includes result.reasons.map(&:name), :has_permission
  end

  def test_propagates_false_from_dependencies
    @engine.set_facts(status: "inactive", role: "admin")
    result = @engine.evaluate(:is_valid)

    assert_equal false, result.value
    is_active = result.reasons.find { |r| r.name == :is_active }
    assert_equal false, is_active.value
  end

  def test_tracks_dependency_chain_in_reasons
    @engine.set_facts(status: "active", role: "admin")
    result = @engine.evaluate(:is_valid)

    is_active = result.reasons.find { |r| r.name == :is_active }
    assert_equal 1, is_active.reasons.length
    assert_equal :status, is_active.reasons.first.name
  end

  def test_caches_evaluated_facts
    @engine.set_facts(status: "active")
    result1 = @engine.evaluate(:is_active)
    result2 = @engine.evaluate(:is_active)
    assert_same result1, result2
  end

  def test_returns_nil_value_for_undefined_rules
    result = @engine.evaluate(:nonexistent_rule)
    assert_nil result.value
    assert_empty result.reasons
  end

  def test_handles_nil_input_values
    @engine.set_facts(status: nil)
    assert_equal false, @engine.evaluate(:is_active).value
  end

  def test_reset_clears_all_cached_facts
    @engine.set_facts(status: "active")
    @engine.evaluate(:is_active)
    @engine.reset!
    @engine.set_facts(status: "inactive")
    assert_equal false, @engine.evaluate(:is_active).value
  end

  def test_all_facts_returns_complete_dependency_tree
    @engine.set_facts(status: "active", role: "admin")
    fact_names = @engine.evaluate(:is_valid).all_facts.map(&:name)

    assert_includes fact_names, :is_valid
    assert_includes fact_names, :is_active
    assert_includes fact_names, :status
    assert_includes fact_names, :role
  end

  def test_failed_facts_returns_only_false_facts
    @engine.set_facts(status: "inactive", role: "guest")
    failed_names = @engine.evaluate(:is_valid).failed_facts.map(&:name)

    assert_includes failed_names, :is_valid
    assert_includes failed_names, :is_active
    assert_includes failed_names, :has_permission
  end

  def test_failed_facts_returns_empty_for_all_passing
    @engine.set_facts(status: "active", role: "admin")
    assert_empty @engine.evaluate(:is_valid).failed_facts
  end

  def test_fact_has_meaningful_to_s
    @engine.set_facts(status: "active")
    assert_equal "Fact(is_active: true)", @engine.evaluate(:is_active).to_s
  end

  def test_fact_has_meaningful_inspect
    @engine.set_facts(status: "active")
    result = @engine.evaluate(:is_active)
    assert_includes result.inspect, "is_active"
    assert_includes result.inspect, "true"
  end
end
