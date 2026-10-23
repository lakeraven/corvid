# frozen_string_literal: true

require "minitest/autorun"
require "bundler/setup"
require "rake"
require "rake/testtask"
require "set"
require "pathname"

class RakeTestTasksTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  OVERLAY_TEST = "test/lib/corvid/demo/fhir_overlay_test.rb"
  RAKE_TEST_TASKS = %w[test_lib test_models].freeze

  def setup
    @rake_test_files = rake_test_task_files_by_name
    @all_test_files = discover_test_files
  end

  def test_fhir_overlay_test_is_scheduled_by_exactly_one_rake_test_task
    tasks = RAKE_TEST_TASKS.select { |name| @rake_test_files[name].include?(OVERLAY_TEST) }
    assert_equal 1, tasks.size,
                 "#{OVERLAY_TEST}: #{tasks.empty? ? "neither (unrun)" : "both #{tasks.join(", ")}"}"
  end

  def test_every_test_rb_file_is_scheduled_by_exactly_one_rake_test_task
    RAKE_TEST_TASKS.each do |name|
      assert_operator @rake_test_files.fetch(name).size, :>, 0,
                      "#{name} has no configured test files (vacuous pass)"
    end

    problems = []

    @all_test_files.each do |file|
      tasks = RAKE_TEST_TASKS.select { |name| @rake_test_files[name].include?(file) }
      case tasks.size
      when 0
        problems << "#{file}: neither (unrun)"
      when 1
        nil
      else
        problems << "#{file}: both #{tasks.join(", ")}"
      end
    end

    assert_empty problems, problems.join("; ")
  end

  private

  def rake_test_task_files_by_name
    captured = {}
    previous_cwd = Dir.pwd

    with_captured_rake_test_tasks(captured) do
      Rake.application.clear
      Rake.application.init
      Dir.chdir(ROOT)
      Rake.load_rakefile(File.join(ROOT, "Rakefile"))

      RAKE_TEST_TASKS.each_with_object({}) do |name, hash|
        task = captured[name]
        raise "missing Rake::TestTask #{name}" unless task

        paths = configured_test_files(task)
        hash[name] = paths.map { |path| normalize_test_path(path) }.to_set
      end
    end
  ensure
    Dir.chdir(previous_cwd)
  end

  def with_captured_rake_test_tasks(captured)
    singleton = class << Rake::TestTask; self; end
    original_new = singleton.instance_method(:new)
    singleton.define_method(:new) do |*args, **kwargs, &block|
      task = original_new.bind_call(Rake::TestTask, *args, **kwargs, &block)
      name = task.name.to_s
      captured[name] = task if RAKE_TEST_TASKS.include?(name)
      task
    end
    yield
  ensure
    singleton.define_method(:new, original_new)
  end

  def configured_test_files(test_task)
    files = []
    test_files = test_task.instance_variable_get(:@test_files)
    files.concat(test_files.to_a) if test_files
    pattern = test_task.pattern
    files.concat(FileList[pattern].to_a) if pattern
    files
  end

  def discover_test_files
    Dir.glob(File.join(ROOT, "test/**/*_test.rb"))
      .reject { |path| path.include?("/test/dummy/") || path.include?("/test/support/") }
      .map { |path| normalize_test_path(path) }
      .sort
  end

  def normalize_test_path(path)
    full = File.expand_path(path, ROOT)
    Pathname.new(full).relative_path_from(Pathname.new(ROOT)).to_s
  end
end
