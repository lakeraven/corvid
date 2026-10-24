# frozen_string_literal: true

require "minitest/autorun"
require "prism"
require "corvid/adapters/base"

# Issue #683: adapter files must not define the same method twice in one class body.
class Corvid::Adapters::NoDuplicateMethodDefinitionsTest < Minitest::Test
  ADAPTER_GLOB = File.expand_path("../../../lib/corvid/adapters/*.rb", __dir__)

  def test_no_duplicate_method_definitions_in_adapter_files
    paths = Dir.glob(ADAPTER_GLOB).sort
    assert_operator paths.size, :>=, 1, "adapter glob matched no files: #{ADAPTER_GLOB}"

    duplicates = paths.flat_map { |path| duplicates_in_file(path) }

    assert_empty duplicates, duplicate_message(duplicates)
  end

  def test_method_def_collector_inline_source_cases
    attr_reader_dup = <<~RUBY
      class Example
        attr_reader :base_url
        def base_url
        end
      end
    RUBY
    assert duplicate_names_in_source(attr_reader_dup).include?(:base_url),
           "expected attr_reader plus def with the same name to be flagged"

    define_method_dup = <<~RUBY
      class Example
        def handler
        end
        define_method(:handler) {}
      end
    RUBY
    assert duplicate_names_in_source(define_method_dup).include?(:handler),
           "expected def plus define_method with the same name to be flagged"

    alias_method_dup = <<~RUBY
      class Example
        def existing
        end
        alias_method :existing, :other
      end
    RUBY
    assert duplicate_names_in_source(alias_method_dup).include?(:existing),
           "expected def plus alias_method with the same new name to be flagged"

    instance_and_singleton = <<~RUBY
      class Example
        def shared
        end
        class << self
          def shared
          end
        end
      end
    RUBY
    assert_empty duplicate_names_in_source(instance_and_singleton),
                 "instance and singleton methods with the same name should not be flagged"

    nested_class = <<~RUBY
      class Outer
        def shared
        end
        class Inner
          def shared
          end
        end
      end
    RUBY
    assert_empty duplicate_names_in_source(nested_class),
                 "the same method name in a nested class should not be flagged"
  end

  def duplicates_in_file(path)
    result = Prism.parse_file(path)
    assert_empty result.errors,
                 "Prism parse errors in #{path}: #{result.errors.map(&:message).join(', ')}"

    duplicates_in_ast(result.value, path)
  end

  def duplicates_in_source(source)
    result = Prism.parse(source)
    assert_empty result.errors,
                 "Prism parse errors in inline source: #{result.errors.map(&:message).join(', ')}"

    duplicates_in_ast(result.value, "(inline)")
  end

  def duplicate_names_in_source(source)
    duplicates_in_source(source).map { |entry| entry[3] }
  end

  def duplicates_in_ast(ast, path)
    collector = MethodDefCollector.new
    collector.visit(ast)
    collector.duplicates(path)
  end

  def duplicate_message(duplicates)
    lines = duplicates.map do |entry|
      file, class_path, kind, name, line_numbers = entry
      scope = kind == :singleton ? ".#{name}" : "##{name}"
      "  #{file} #{class_path}#{scope} (#{kind}) lines #{line_numbers.join(', ')}"
    end
    "duplicate method definitions in adapter files:\n#{lines.join("\n")}"
  end

  class MethodDefCollector < Prism::Visitor
    ATTR_METHODS = %i[attr_reader attr_writer attr_accessor].freeze

    def initialize
      @path_stack = []
      @singleton_depth = 0
      @defs_by_scope = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
      super()
    end

    def visit_module_node(node)
      @path_stack.push(constant_name(node.constant_path))
      previous_singleton_depth = @singleton_depth
      @singleton_depth = 0
      super
      @singleton_depth = previous_singleton_depth
      @path_stack.pop
    end

    def visit_class_node(node)
      @path_stack.push(constant_name(node.constant_path))
      previous_singleton_depth = @singleton_depth
      @singleton_depth = 0
      super
      @singleton_depth = previous_singleton_depth
      @path_stack.pop
    end

    def visit_singleton_class_node(node)
      @singleton_depth += 1
      super
      @singleton_depth -= 1
    end

    def visit_def_node(node)
      if countable_def?(node)
        record_method(node.name, node.location.start_line, method_kind_for_def(node))
      end
      super
    end

    def visit_call_node(node)
      if countable_call?(node)
        case node.name
        when :attr_reader
          record_attr_literals(node, :reader)
        when :attr_writer
          record_attr_literals(node, :writer)
        when :attr_accessor
          record_attr_literals(node, :reader)
          record_attr_literals(node, :writer)
        when :define_method
          record_define_method(node)
        when :alias_method
          record_alias_method_call(node)
        end
      end
      super
    end

    def visit_alias_method_node(node)
      record_literal_method_name(node.new_name, node.location.start_line)
      super
    end

    def duplicates(path)
      @defs_by_scope.flat_map do |(class_path, kind), names|
        names.filter_map do |name, line_numbers|
          next if line_numbers.size < 2

          [ path, class_path, kind, name, line_numbers.sort ]
        end
      end
    end

    private

    def countable_def?(node)
      receiver = node.receiver
      receiver.nil? || receiver.is_a?(Prism::SelfNode)
    end

    def countable_call?(node)
      return false unless ATTR_METHODS.include?(node.name) ||
                          node.name == :define_method ||
                          node.name == :alias_method

      receiver = node.receiver
      receiver.nil? || receiver.is_a?(Prism::SelfNode)
    end

    def record_define_method(node)
      return unless node.arguments

      first_arg = node.arguments.arguments.first
      record_literal_method_name(first_arg, node.location.start_line)
    end

    def record_alias_method_call(node)
      return unless node.arguments

      first_arg = node.arguments.arguments.first
      record_literal_method_name(first_arg, node.location.start_line)
    end

    def record_attr_literals(node, role)
      return unless node.arguments

      node.arguments.arguments.each do |argument|
        literal = literal_method_name(argument, role)
        record_method(literal, node.location.start_line) if literal
      end
    end

    def record_literal_method_name(node, line)
      name = literal_method_name(node, :reader)
      record_method(name, line) if name
    end

    def literal_method_name(node, role)
      base_name =
        case node
        when Prism::SymbolNode, Prism::StringNode
          node.unescaped
        else
          return nil
        end

      role == :writer ? :"#{base_name}=" : base_name.to_sym
    end

    def record_method(name, line, kind = current_kind)
      scope_key = [ @path_stack.join("::"), kind ]
      @defs_by_scope[scope_key][name] << line
    end

    def method_kind_for_def(node)
      (@singleton_depth > 0 || node.receiver.is_a?(Prism::SelfNode)) ? :singleton : :instance
    end

    def current_kind
      @singleton_depth > 0 ? :singleton : :instance
    end

    def constant_name(constant_path)
      constant_path.location.slice
    end
  end
end
