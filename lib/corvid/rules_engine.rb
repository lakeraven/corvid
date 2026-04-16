# frozen_string_literal: true

module Corvid
  # A generic rules engine that evaluates facts based on defined rules.
  # Uses dependency injection for rule sets and maintains a fact cache.
  #
  # Rules are defined as methods on a ruleset class. Method parameters
  # automatically declare dependencies - the engine builds a DAG and
  # evaluates dependencies before the dependent rule.
  #
  # Example:
  #   class MyRuleset
  #     def is_eligible(is_enrolled, meets_residency)
  #       is_enrolled && meets_residency
  #     end
  #
  #     def is_enrolled(enrollment_number)
  #       enrollment_number.present?
  #     end
  #
  #     def meets_residency(service_area)
  #       ["Anchorage", "Fairbanks"].include?(service_area)
  #     end
  #   end
  #
  #   engine = Corvid::RulesEngine.new(MyRuleset.new)
  #   engine.set_facts(enrollment_number: "ABC-123", service_area: "Anchorage")
  #   result = engine.evaluate(:is_eligible)
  #   # result.value => true
  class RulesEngine
    class Fact
      attr_reader :name, :value, :reasons

      def initialize(name, value, reasons: [])
        @name = name
        @value = value
        @reasons = reasons
      end

      def all_facts
        result = [self]
        reasons.each { |reason| result.concat(reason.all_facts) }
        result
      end

      def failed_facts
        all_facts.reject { |fact| fact.value }
      end

      def to_s
        "Fact(#{name}: #{value})"
      end

      def inspect
        "#<Corvid::RulesEngine::Fact name=#{name.inspect} value=#{value.inspect} reasons=#{reasons.map(&:name).inspect}>"
      end
    end

    class Input < Fact
      def initialize(name, value)
        super(name, value, reasons: [])
      end
    end

    attr_reader :rules, :facts

    def initialize(rules)
      @rules = rules
      @facts = {}
    end

    def set_facts(facts)
      facts.each do |name, value|
        @facts[name] = Input.new(name, value)
      end
    end

    def evaluate(fact_name)
      fact_name = fact_name.to_sym
      return @facts[fact_name] if @facts.key?(fact_name)

      result = compute_fact(fact_name)
      @facts[fact_name] = result
      result
    end

    def all_evaluated_facts
      @facts.dup
    end

    def reset!
      @facts = {}
    end

    private

    def compute_fact(fact_name)
      unless @rules.respond_to?(fact_name)
        return Fact.new(fact_name, nil, reasons: [])
      end

      func = @rules.method(fact_name)
      func_inputs = func.parameters.map { |_type, name| name }
      args = func_inputs.map { |name| evaluate(name)&.value }
      result = func.call(*args)
      Fact.new(fact_name, result, reasons: func_inputs.map { |name| @facts[name] })
    end
  end
end
