# frozen_string_literal: true

require "minitest/autorun"
require "bundler/setup"
require "pathname"
require "set"

class Gm6MlrMethodologyDocTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DOC = File.join(ROOT, "docs/gm6_mlr_savings_methodology.md")

  STANDARD_RAILS_TASKS = %w[
    db:prepare
    db:create
    db:migrate
    db:schema:load
  ].freeze

  RAILS_TASK_PATTERN = %r{
    (?:^|\s)
    (?:
      bin/rails |
      bundle \s+ exec \s+ rails
    )
    \s+
    (?<task>[a-z][a-z0-9_:]*)
    (?:\[[^\]]*\])?
    (?=[\s#&|;]|$)
  }ix

  RAKE_TASK_PATTERN = %r{
    (?:^|\s)
    rake \s+
    (?<task>[a-z][a-z0-9_:]*)
    (?:\[[^\]]*\])?
    (?=[\s#&|;]|$)
  }ix

  DEMO_LINE_PATTERN = %r{
    demo:mlr_savings |
    bin/demo[-\w]*mlr |
    demo-mlr
  }ix

  DUMMY_BUNDLE_INSTALL_PATTERN = %r{
    test/dummy
    .*?
    \bbundle \s+ (?:check \s* \|\| \s*)? install \b
  }ix

  def setup
    @doc = File.read(DOC)
    @defined_tasks = defined_rake_tasks
  end

  def test_doc_commands_do_not_set_rails_env_to_test
    offenders = doc_shell_commands.select { |cmd| command_sets_rails_env_test?(cmd) }
    assert_empty offenders,
                 "commands must not set RAILS_ENV=test (use development): #{offenders.join(" | ")}"
  end

  def test_doc_rake_tasks_are_defined
    tasks = doc_runnable_tasks
    undefined = tasks.reject { |task| task_defined?(task) }.sort.uniq
    assert_empty undefined,
                 "undefined rake/rails tasks in #{DOC}: #{undefined.join(", ")}"
  end

  def test_reproduce_block_runs_demo_in_development
    demo_lines = reproduce_demo_lines
    assert_operator demo_lines.size, :>, 0,
                    "Reproduce block must include a demo:mlr_savings (or bin/demo-*) command"

    bad = demo_lines.reject { |line| demo_line_runs_in_development?(line) }
    assert_empty bad,
                 "Reproduce demo must use RAILS_ENV=development or a bin/demo-* entry point: #{bad.join(" | ")}"
  end

  def test_reproduce_block_installs_dummy_gems_before_bin_rails
    block = reproduce_bash_block
    assert block, "Reproduce block must include a ```bash``` snippet"

    offenders = []
    dummy_gems_ready = false
    reproduce_shell_lines.each do |line|
      dummy_gems_ready = true if line.match?(DUMMY_BUNDLE_INSTALL_PATTERN)
      next unless bin_rails_in_test_dummy?(line)
      next if dummy_gems_ready

      offenders << line
    end

    assert_empty offenders,
                 "install test/dummy gems (bundle check || bundle install) before bin/rails there: " \
                 "#{offenders.join(" | ")}"
  end

  private

  def doc_shell_commands
    bash_blocks.flat_map { |block| shell_lines(block) }
  end

  def bash_blocks
    blocks = []
    in_bash = false
    buffer = []

    @doc.each_line do |line|
      if line.start_with?("```bash")
        in_bash = true
        buffer = []
        next
      end
      if in_bash && line.start_with?("```")
        blocks << buffer.join("\n")
        in_bash = false
        next
      end
      buffer << line if in_bash
    end

    blocks
  end

  def shell_lines(block)
    block.lines.filter_map do |line|
      stripped = line.split("#", 2).first&.strip
      stripped if stripped && !stripped.empty?
    end
  end

  def command_sets_rails_env_test?(command)
    command.match?(/\bRAILS_ENV\s*=\s*test\b/i)
  end

  def doc_runnable_tasks
    doc_shell_commands.flat_map { |cmd| tasks_from_command(cmd) }.uniq
  end

  def tasks_from_command(command)
    tasks = []
    [ RAILS_TASK_PATTERN, RAKE_TASK_PATTERN ].each do |pattern|
      command.scan(pattern) { tasks << Regexp.last_match[:task] }
    end
    tasks
  end

  def task_defined?(task)
    STANDARD_RAILS_TASKS.include?(task) || @defined_tasks.include?(task)
  end

  def reproduce_demo_lines
    block = reproduce_bash_block
    return [] unless block

    shell_lines(block).select { |line| line.match?(DEMO_LINE_PATTERN) }
  end

  def reproduce_shell_lines
    block = reproduce_bash_block
    return [] unless block

    shell_lines(block)
  end

  def bin_rails_in_test_dummy?(line)
    return false unless line.match?(%r{\b(?:bin/rails|bundle \s+ exec \s+ rails)\b}ix)
    return false unless line.match?(%r{test/dummy\b}ix)

    true
  end

  def reproduce_bash_block
    lines = @doc.lines
    reproduce_idx = lines.index { |line| line.match?(/\*\*Reproduce:\*\*/) }
    return nil unless reproduce_idx

    in_bash = false
    buffer = []
    lines.drop(reproduce_idx + 1).each do |line|
      if line.start_with?("```bash")
        in_bash = true
        next
      end
      if in_bash && line.start_with?("```")
        return buffer.join("\n")
      end
      buffer << line if in_bash
    end

    nil
  end

  def demo_line_runs_in_development?(line)
    return true if line.match?(%r{\bbin/demo[-\w]*\b})
    return true if line.match?(/\bRAILS_ENV\s*=\s*development\b/i)

    false
  end

  def defined_rake_tasks
    tasks = Set.new
    rake_files = Dir.glob(File.join(ROOT, "lib/tasks/*.rake")) +
                 Dir.glob(File.join(ROOT, "test/dummy/lib/tasks/*.rake"))

    rake_files.each do |path|
      namespaces = []
      File.read(path).scan(/^\s*(.+)$/) do |(raw)|
        line = raw.strip
        if (m = line.match(/^namespace\s+:(\w+)\s+do\s*$/))
          namespaces << m[1]
          next
        end
        if line == "end"
          namespaces.pop
          next
        end

        task_name = task_name_from_declaration(line)
        next unless task_name

        full_name = if task_name.include?(":")
          task_name
        else
          ([ *namespaces, task_name ].join(":"))
        end
        tasks << full_name
      end
    end

    tasks
  end

  def task_name_from_declaration(line)
    return Regexp.last_match(1) if line.match(/^task\s+"([^"]+)"/)
    return Regexp.last_match(1) if line.match(/^task\s+:(\w+)/)
    return Regexp.last_match(1) if line.match(/^task\s+(\w+):/)

    nil
  end
end
