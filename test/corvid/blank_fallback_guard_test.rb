# frozen_string_literal: true

require "minitest/autorun"
require "prism"
require "corvid/version"

class Corvid::BlankFallbackGuardTest < Minitest::Test
  # `||` only skips nil/false; blank strings are truthy and win over fallbacks.
  # User-facing labels should use `presence ||` so nil and blank both defer.
  LABEL_METHOD_NAMES = %i[
    display_name display label release_label name title text program_name
  ].freeze
  LABEL_HASH_KEYS = %w[display text name label].freeze

  ROOTS = %w[app lib].freeze

  def test_or_left_operand_visitor_inline_cases
    cases = {
      'x.presence || y.display_name || "z"' => 1,
      "a.display_name || b" => 1,
      'a.display_name.presence || b.text.presence || "c"' => 0,
      "tenant_identifier || ctx" => 1,
      's[/re/, 1] || "stub"' => 0,
      "x ||= y.name" => 0,
      'args[:label] || "manual"' => 1
    }

    cases.each do |source, expected|
      violations = []
      visitor = OrLeftOperandVisitor.new("(inline)", violations)
      visitor.visit(Prism.parse(source).value)
      assert_equal expected, violations.size, "expected #{expected} violation(s) for: #{source}"
    end
  end

  def test_no_raw_or_fallback_on_label_like_expressions
    violations = []
    ROOTS.each do |root|
      Dir.glob(File.expand_path("../../#{root}/**/*.rb", __dir__)).sort.each do |path|
        scan_file(path, violations)
      end
    end
    Dir.glob(File.expand_path("../../lib/tasks/**/*.rake", __dir__)).sort.each do |path|
      scan_file(path, violations)
    end

    assert_empty violations,
      "use `presence ||` for label-like fallbacks (blank strings are truthy in Ruby):\n" \
      "#{violations.join("\n")}"
  end

  def scan_file(path, violations)
    source = File.read(path)
    visitor = OrLeftOperandVisitor.new(path, violations)
    visitor.visit(Prism.parse(source, filepath: path).value)
  end

  class OrLeftOperandVisitor < Prism::Visitor
    def initialize(path, violations)
      @path = path
      @violations = violations
      super()
    end

    def visit_or_node(node)
      operands = flatten_or_chain(node)
      operands[0..-2].each do |operand|
        if offending_operand?(operand)
          loc = operand.location
          @violations << "#{@path}:#{loc.start_line}"
        end
      end
      operands.each { |operand| operand.accept(self) }
    end

    def flatten_or_chain(node)
      node = unwrap_parentheses(node)
      return [ node ] unless node.is_a?(Prism::OrNode)

      flatten_or_chain(node.left) + flatten_or_chain(node.right)
    end

    def unwrap_parentheses(node)
      while node.is_a?(Prism::ParenthesesNode)
        node = node.body
      end
      node
    end

    def offending_operand?(node)
      node = unwrap_parentheses(node)
      return false if node.is_a?(Prism::CallNode) && node.name == :presence
      return false if regex_capture_index?(node)

      if node.is_a?(Prism::LocalVariableReadNode) && label_like_local?(node.name)
        return true
      end

      return false unless node.is_a?(Prism::CallNode)

      if node.receiver.nil? && label_like_local?(node.name)
        return true
      end

      return true if LABEL_METHOD_NAMES.include?(node.name)
      return true if index_access_label_key?(node)
      return true if dig_includes_label_key?(node)

      false
    end

    def label_like_local?(name)
      name = name.to_s
      name == "label" || name == "display_name" ||
        name.end_with?("_identifier", "_label")
    end

    def regex_capture_index?(node)
      return false unless node.is_a?(Prism::CallNode) && node.name == :[]

      first = Array(node.arguments&.arguments).first
      first.is_a?(Prism::RegularExpressionNode)
    end

    def index_access_label_key?(call_node)
      return false unless call_node.name == :[]

      index_arguments(call_node).any? { |key| LABEL_HASH_KEYS.include?(key) }
    end

    def dig_includes_label_key?(call_node)
      return false unless call_node.name == :dig

      index_arguments(call_node).any? { |key| LABEL_HASH_KEYS.include?(key) }
    end

    def index_arguments(call_node)
      Array(call_node.arguments&.arguments).filter_map do |arg|
        case arg
        when Prism::StringNode, Prism::SymbolNode then arg.unescaped
        end
      end
    end
  end
  private_constant :OrLeftOperandVisitor
end
