# frozen_string_literal: true

require "minitest/autorun"
require "prism"

class Corvid::BlankFallbackGuardTest < Minitest::Test
  # `||` only skips nil/false; blank strings are truthy and win over fallbacks.
  # User-facing labels should use `presence ||` so nil and blank both defer.
  LABEL_METHOD_NAMES = %i[
    display_name display label release_label name title text program_name
  ].freeze
  LABEL_INDEX_KEYS = %w[display text].freeze

  ROOTS = %w[app lib].freeze

  def test_no_raw_or_fallback_on_label_like_expressions
    violations = []
    ROOTS.each do |root|
      Dir.glob(File.expand_path("../../#{root}/**/*.rb", __dir__)).sort.each do |path|
        scan_file(path, violations)
      end
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
      if offending_left?(node.left)
        @violations << "#{@path}:#{node.location.start_line}"
      end
      super
    end

    def offending_left?(left)
      return false unless left.is_a?(Prism::CallNode)
      return false if left.name == :presence
      return true if LABEL_METHOD_NAMES.include?(left.name)
      return true if index_access_label_key?(left)
      return true if dig_includes_label_key?(left)

      false
    end

    def index_access_label_key?(call_node)
      return false unless call_node.name == :[]

      index_arguments(call_node).any? { |key| LABEL_INDEX_KEYS.include?(key) }
    end

    def dig_includes_label_key?(call_node)
      return false unless call_node.name == :dig

      index_arguments(call_node).any? { |key| LABEL_INDEX_KEYS.include?(key) }
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
