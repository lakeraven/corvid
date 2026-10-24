# frozen_string_literal: true

require "minitest/autorun"
require "prism"
require "corvid/adapters/base"

# Issue #683: adapter files must not define the same method twice in one class body.
class Corvid::Adapters::NoDuplicateMethodDefinitionsTest < Minitest::Test
  ADAPTER_GLOB = File.expand_path("../../../lib/corvid/adapters/*.rb", __dir__)

  def test_no_duplicate_method_definitions_in_adapter_files
    duplicates = Dir.glob(ADAPTER_GLOB).sort.flat_map { |path| duplicates_in_file(path) }

    assert_empty duplicates, duplicate_message(duplicates)
  end

  def duplicates_in_file(path)
    collector = MethodDefCollector.new
    collector.visit(Prism.parse_file(path).value)
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
    def initialize
      @path_stack = []
      @singleton_depth = 0
      @defs_by_scope = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
      super()
    end

    def visit_module_node(node)
      @path_stack.push(constant_name(node.constant_path))
      super
      @path_stack.pop
    end

    def visit_class_node(node)
      @path_stack.push(constant_name(node.constant_path))
      super
      @path_stack.pop
    end

    def visit_singleton_class_node(node)
      @singleton_depth += 1
      super
      @singleton_depth -= 1
    end

    def visit_def_node(node)
      kind = singleton_method?(node) ? :singleton : :instance
      scope_key = [ @path_stack.join("::"), kind ]
      @defs_by_scope[scope_key][node.name] << node.location.start_line
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

    def constant_name(constant_path)
      constant_path.location.slice
    end

    def singleton_method?(node)
      @singleton_depth > 0 || node.receiver.is_a?(Prism::SelfNode)
    end
  end
end
