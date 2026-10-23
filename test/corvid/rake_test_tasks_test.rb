# frozen_string_literal: true

require "minitest/autorun"
require "bundler/setup"
require "rake"
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

  def load_rake_tasks_without_running
    previous = Dir.getwd
    Dir.chdir(ROOT)
    Rake.application.clear
    Rake.application.init
    Rake.application.load_rakefile
  ensure
    Dir.chdir(previous) if previous
  end

  def rake_test_task_files_by_name
    load_rake_tasks_without_running

    RAKE_TEST_TASKS.each_with_object({}) do |name, hash|
      task = ObjectSpace.each_object(Rake::TestTask).find { |t| t.name.to_s == name }
      raise "missing Rake::TestTask #{name}" unless task

      hash[name] = task.file_list.to_a.map { |path| normalize_test_path(path) }.to_set
    end
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
