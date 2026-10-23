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

  COMMAND_TASK_EXTRACTOR = %r{
    (?:^|[\s;&|])
    (?:
      bin/rails |
      bundle \s+ exec \s+ rails |
      bundle \s+ exec \s+ rake |
      rake
    )
    \s+
    (?:
      "(?<qtask>[^"]+)" |
      '(?<sqtask>[^']+)' |
      (?<utask>[a-z][a-z0-9_:]*)(?:\[[^\]]*\])?
    )
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

  INLINE_SHELL_COMMAND_PATTERN = %r{
    \A
    (?:
      cd \s+ test/dummy \s+ && \s+
    )?
    (?:
      RAILS_ENV \s* = \s* \S+ \s+
    )?
    (?:
      bin/rails |
      bundle \s+ exec \s+ rails |
      bundle \s+ exec \s+ rake |
      rake
    )
    \s+
    .+
  }ix

  DEMO_TEST_ENV_COMMAND = "cd test/dummy && RAILS_ENV=test bin/rails demo:mlr_savings"

  FENCE_STYLE_SAMPLES = [
    [ "```bash\n#{DEMO_TEST_ENV_COMMAND}\n```", "column-0 bash backticks" ],
    [ "```sh\n#{DEMO_TEST_ENV_COMMAND}\n```", "sh info string" ],
    [ "```shell\n#{DEMO_TEST_ENV_COMMAND}\n```", "shell info string" ],
    [ "```console\n#{DEMO_TEST_ENV_COMMAND}\n```", "console info string" ],
    [ "~~~bash\n#{DEMO_TEST_ENV_COMMAND}\n~~~", "tilde bash fence" ],
    [ "~~~sh\n#{DEMO_TEST_ENV_COMMAND}\n~~~", "tilde sh fence" ],
    [ "1. step\n   ```bash\n   #{DEMO_TEST_ENV_COMMAND}\n   ```\n", "list-nested bash fence" ]
  ].freeze

  SHELL_FENCE_INFO = /\A(?:bash|sh|shell|console)\z/i

  def setup
    @doc = File.read(DOC, encoding: "UTF-8")
    @defined_tasks = defined_rake_tasks
  end

  def test_defined_rake_task_parser_recognises_nested_cms_tasks
    %w[
      cms:ipps:fetch_release
      cms:opps:fetch_release
      cms:import
    ].each do |task|
      assert_includes @defined_tasks, task, "expected nested rake task #{task} to be defined"
    end
  end

  def test_doc_commands_do_not_set_rails_env_to_test
    offenders = doc_all_shell_commands.select { |cmd| command_sets_rails_env_test?(cmd) }
    assert_empty offenders,
                 "commands must not set RAILS_ENV=test (use development): #{offenders.join(" | ")}"
  end

  def test_all_fence_styles_extract_commands_for_rails_env_test_check
    FENCE_STYLE_SAMPLES.each do |snippet, label|
      offenders = shell_commands_from_markdown(snippet).select { |cmd| command_sets_rails_env_test?(cmd) }
      refute_empty offenders,
                   "#{label} fence must surface RAILS_ENV=test demo command for checks: #{snippet.inspect}"
    end
  end

  def test_inline_demo_test_env_command_is_checked
    offenders = shell_commands_from_markdown("run `#{DEMO_TEST_ENV_COMMAND}` once")
      .select { |cmd| command_sets_rails_env_test?(cmd) }
    refute_empty offenders, "inline span must be checked for RAILS_ENV=test"
  end

  def test_doc_rake_tasks_are_defined
    tasks = doc_runnable_tasks
    undefined = tasks.reject { |task| task_defined?(task) }.sort.uniq
    assert_empty undefined,
                 "undefined rake/rails tasks in #{DOC}: #{undefined.join(", ")}"
  end

  def test_doc_shell_commands_are_runnable_from_reader_context
    offenders = doc_all_shell_commands.reject { |cmd| runnable_from_reader_context?(cmd) }
    assert_empty offenders,
                 "commands must run from the reader context (test/dummy bin/rails, quoted args): " \
                 "#{offenders.join(" | ")}"
  end

  def test_reproduce_section_warns_about_database_url
    assert_match(/DATABASE_URL/, reproduce_section_text,
                 "Reproduce section must warn that DATABASE_URL overrides the environment")
  end

  def test_reproduce_section_warns_test_database_rate_row_hazard
    text = reproduce_section_text
    assert_match(/test\s+database/i, text,
                 "Reproduce section must name the test-database hazard explicitly")
    assert_match(/rate\s+row/i, text,
                 "Reproduce section must warn that rate rows are left in the test database")
    assert_match(/delete|reinsert|recreated/i, text,
                 "Reproduce section must describe delete-and-reinsert behaviour")
  end

  def test_reproduce_section_does_not_claim_test_database_wipe
    refute_match(/\bwipe(?:s)?\s+the\s+test\s+database\b/i, reproduce_section_text,
                 "Reproduce section must not claim the demo wipes the test database")
  end

  def test_reproduce_block_unsets_database_url_before_rails
    offenders = reproduce_rails_lines_before_database_url_unset
    assert_empty offenders,
                 "Reproduce shell block must unset DATABASE_URL (or env -u) before bin/rails: " \
                 "#{offenders.join(" | ")}"
  end

  def test_line_clears_database_url_rejects_echo_and_conditional_mutations
    refute line_clears_database_url?("echo unset DATABASE_URL"),
           "echo mentioning unset must not count as clearing DATABASE_URL"
    refute line_clears_database_url?('[ -n "$X" ] && unset DATABASE_URL'),
           "conditional unset must not count as clearing DATABASE_URL"
    assert line_clears_database_url?("unset DATABASE_URL")
    assert line_clears_database_url?("unset OTHER_VAR DATABASE_URL")
  end

  def test_doc_outside_reproduce_bin_rails_commands_clear_database_url
    offenders = bin_rails_test_dummy_commands_outside_reproduce_shell_fence
      .reject { |entry| command_includes_database_url_clear?(entry[:command]) }
    assert_empty offenders,
                 "every test/dummy bin/rails command outside the Reproduce shell block must clear " \
                 "DATABASE_URL (unset DATABASE_URL && or env -u DATABASE_URL): " \
                 "#{offenders.map { |e| e[:command] }.join(" | ")}"
  end

  def test_doc_commands_use_numeric_task_arguments_only
    offenders = doc_all_shell_commands.select { |cmd| command_has_placeholder_bracket_args?(cmd) }
    assert_empty offenders,
                 "command spans must use numeric bracket args, not placeholders like [year]: " \
                 "#{offenders.join(" | ")}"
  end

  def test_quoted_rails_task_names_are_extracted_for_definition_check
    cmd = 'cd test/dummy && RAILS_ENV=development bin/rails "cms:nonexistent_task[2026]"'
    undefined = tasks_from_command(cmd).reject { |task| task_defined?(task) }
    refute_empty undefined, "quoted bin/rails task names must be checked for definition"
    assert_includes undefined, "cms:nonexistent_task"
  end

  def test_bare_rake_from_repo_root_fails_reader_context_check
    [
      "rake cms:import",
      "rake demo:mlr_savings"
    ].each do |cmd|
      refute runnable_from_reader_context?(cmd),
             "bare rake from repo root must fail reader context: #{cmd}"
    end
  end

  def test_bundle_exec_rake_spans_are_shell_commands_and_checked
    spans = [
      "RAILS_ENV=development bundle exec rake demo:mlr_savings",
      "bundle exec rake cms:import[2026]"
    ]
    spans.each do |span|
      assert_match INLINE_SHELL_COMMAND_PATTERN, span,
                   "inline shell pattern must match bundle exec rake: #{span}"
    end

    refute runnable_from_reader_context?("bundle exec rake cms:import[2026]"),
           "bundle exec rake without test/dummy must fail reader context"
    undefined = tasks_from_command("bundle exec rake cms:totally_fake_task").reject do |task|
      task_defined?(task)
    end
    refute_empty undefined, "bundle exec rake task names must be checked for definition"
    assert_includes undefined, "cms:totally_fake_task"
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
    block = reproduce_shell_fence_block
    assert block, "Reproduce section must include a fenced shell snippet"

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

  def shell_commands_from_markdown(text)
    fenced_shell_command_lines(text) + inline_shell_commands_from(text)
  end

  def doc_all_shell_commands
    shell_commands_from_markdown(@doc)
  end

  def fenced_shell_command_lines(text)
    fenced_code_blocks_with_info(text).flat_map do |block, info|
      lines = shell_lines(block)
      if shell_fence_info?(info)
        lines
      else
        lines.select { |line| looks_like_shell_command_line?(line) }
      end
    end
  end

  def shell_fence_info?(info)
    info&.match?(SHELL_FENCE_INFO)
  end

  def looks_like_shell_command_line?(line)
    return true if line.match?(INLINE_SHELL_COMMAND_PATTERN)
    return true if line.match?(/\A(?:unset|export|env|cd|bundle|RAILS_ENV=)/i)

    line.match?(/\b(?:bin\/rails|bundle \s+ exec \s+ rails|bundle \s+ exec \s+ rake|rake)\b/i)
  end

  def inline_shell_commands_from(text)
    inline_code_spans_from(text).select { |span| span.match?(INLINE_SHELL_COMMAND_PATTERN) }
  end

  def fenced_code_blocks_with_info(text)
    blocks = []
    in_fence = false
    open_marker = nil
    open_info = nil
    buffer = []

    text.each_line do |line|
      if in_fence
        if fence_close?(line, open_marker)
          blocks << [ buffer.join, open_info ]
          in_fence = false
          buffer = []
        else
          buffer << line
        end
      elsif (open = parse_fence_open(line))
        in_fence = true
        open_marker = open[:marker]
        open_info = open[:info]
        buffer = []
      end
    end

    blocks
  end

  def parse_fence_open(line)
    match = line.match(/^(\s*)(`{3,}|~{3,})([^\s`~]*)(.*)$/)
    return nil unless match

    { marker: match[2], info: match[3] }
  end

  def fence_close?(line, open_marker)
    match = line.match(/^(\s*)(`{3,}|~{3,})\s*$/)
    return false unless match

    close_marker = match[2]
    close_marker[0] == open_marker[0] && close_marker.length >= open_marker.length
  end

  def inline_code_spans_from(text)
    spans = []
    in_fence = false
    open_marker = nil

    text.each_line do |line|
      if in_fence
        in_fence = false if fence_close?(line, open_marker)
        next
      end

      if (open = parse_fence_open(line))
        in_fence = true
        open_marker = open[:marker]
        next
      end

      line.scan(/`([^`\n]+)`/) { spans << Regexp.last_match(1) }
    end

    spans
  end

  def command_sets_rails_env_test?(command)
    command.match?(/\bRAILS_ENV\s*=\s*test\b/i)
  end

  def doc_runnable_tasks
    doc_all_shell_commands.flat_map { |cmd| tasks_from_command(cmd) }.uniq
  end

  def tasks_from_command(command)
    tasks = []
    command.scan(COMMAND_TASK_EXTRACTOR) do
      raw = Regexp.last_match[:qtask] || Regexp.last_match[:sqtask] || Regexp.last_match[:utask]
      tasks << task_name_from_token(raw) if raw
    end
    tasks
  end

  def task_name_from_token(token)
    token.sub(/\[.*\]\z/, "")
  end

  def runnable_from_reader_context?(command)
    return true if command.match?(/\Abundle \s+ install\z/i)
    return true if command.match?(/\Acd \s+ test\/dummy \s+ && \s+ bundle \s+ install\z/i)
    return true if command.match?(/\Acd \s+ test\/dummy \s+ && \s+ cd \s+\.\.\/\.\.\z/i)

    if command.match?(
      /\b(?:bin\/rails|bundle \s+ exec \s+ rails|bundle \s+ exec \s+ rake|rake)\b/i
    ) && !command.match?(/test\/dummy/i)
      return false
    end

    return false if shell_task_args_need_quoting?(command)

    true
  end

  def shell_task_args_need_quoting?(command)
    return false unless command.match?(/\[[^\]]+\]/)

    command.match?(
      %r{
        (?:^|\s)
        (?:
          bin/rails |
          bundle \s+ exec \s+ rails |
          bundle \s+ exec \s+ rake |
          rake
        )
        \s+
        [a-z][a-z0-9_:]*\[[^\]]+\]
      }ix
    )
  end

  def task_defined?(task)
    STANDARD_RAILS_TASKS.include?(task) || @defined_tasks.include?(task)
  end

  def reproduce_section_text
    lines = @doc.lines
    reproduce_idx = lines.index { |line| line.match?(/\*\*Reproduce:\*\*/) }
    return "" unless reproduce_idx

    section = []
    lines.drop(reproduce_idx + 1).each do |line|
      break if line.start_with?("## ")
      section << line
    end
    section.join
  end

  def reproduce_demo_lines
    block = reproduce_shell_fence_block
    return [] unless block

    shell_lines(block).select { |line| line.match?(DEMO_LINE_PATTERN) }
  end

  def reproduce_shell_lines
    block = reproduce_shell_fence_block
    return [] unless block

    shell_lines(block)
  end

  def bin_rails_in_test_dummy?(line)
    return false unless line.match?(%r{\b(?:bin/rails|bundle \s+ exec \s+ rails)\b}ix)
    return false unless line.match?(%r{test/dummy\b}ix)

    true
  end

  def bin_rails_test_dummy_command?(command)
    bin_rails_in_test_dummy?(command)
  end

  def bin_rails_test_dummy_commands_outside_reproduce_shell_fence
    fence_range = reproduce_shell_fence_content_line_range
    entries = []

    each_fenced_shell_command_line_with_line(@doc) do |command, line_no, _info|
      next unless bin_rails_test_dummy_command?(command)
      next if fence_range&.cover?(line_no)

      entries << { command: command, line: line_no }
    end

    each_inline_shell_command_with_line(@doc) do |command, line_no|
      next unless bin_rails_test_dummy_command?(command)
      next if fence_range&.cover?(line_no)

      entries << { command: command, line: line_no }
    end

    entries
  end

  def each_fenced_shell_command_line_with_line(text)
    line_no = 0
    in_fence = false
    open_marker = nil
    open_info = nil
    buffer = []
    content_line_no = nil

    text.each_line do |line|
      line_no += 1
      if in_fence
        if fence_close?(line, open_marker)
          lines = shell_lines(buffer.join)
          lines = lines.select { |cmd| looks_like_shell_command_line?(cmd) } unless shell_fence_info?(open_info)
          lines.each_with_index do |command, idx|
            yield command, content_line_no + idx, open_info
          end
          in_fence = false
          buffer = []
        else
          buffer << line
        end
      elsif (open = parse_fence_open(line))
        in_fence = true
        open_marker = open[:marker]
        open_info = open[:info]
        buffer = []
        content_line_no = line_no + 1
      end
    end
  end

  def each_inline_shell_command_with_line(text)
    line_no = 0
    in_fence = false
    open_marker = nil

    text.each_line do |line|
      line_no += 1
      if in_fence
        in_fence = false if fence_close?(line, open_marker)
        next
      end

      if (open = parse_fence_open(line))
        in_fence = true
        open_marker = open[:marker]
        next
      end

      line.scan(/`([^`\n]+)`/) do
        span = Regexp.last_match(1)
        yield span, line_no if span.match?(INLINE_SHELL_COMMAND_PATTERN)
      end
    end
  end

  def reproduce_shell_fence_content_line_range
    lines = @doc.lines
    reproduce_idx = lines.index { |line| line.match?(/\*\*Reproduce:\*\*/) }
    return nil unless reproduce_idx

    line_no = 0
    in_fence = false
    open_marker = nil
    content_start = nil

    lines.each_with_index do |line, idx|
      line_no = idx + 1
      next if idx <= reproduce_idx
      break if line.start_with?("## ") && idx > reproduce_idx

      if in_fence
        if fence_close?(line, open_marker)
          return (content_start...(line_no))
        end
      elsif parse_fence_open(line)
        in_fence = true
        open_marker = parse_fence_open(line)[:marker]
        content_start = line_no + 1
      end
    end

    nil
  end

  def reproduce_rails_lines_before_database_url_unset
    lines = reproduce_shell_lines
    return [] if lines.empty?

    database_url_cleared = false
    offenders = []
    lines.each do |line|
      database_url_cleared = true if line_clears_database_url?(line)
      next unless line.match?(/\b(?:bin\/rails|bundle \s+ exec \s+ rails)\b/i)

      ok = database_url_cleared || rails_line_uses_env_u_database_url?(line)
      offenders << line unless ok
    end
    offenders
  end

  def line_clears_database_url?(line)
    stripped = line.split("#", 2).first&.strip
    return false unless stripped

    stripped.match?(/\Aunset\s+(?:[A-Za-z_][A-Za-z0-9_]*\s+)*DATABASE_URL(?:\s+[A-Za-z_][A-Za-z0-9_]*)*\z/i)
  end

  def rails_line_uses_env_u_database_url?(line)
    line.match?(/\benv\s+-u\s+DATABASE_URL\b/i)
  end

  def command_includes_database_url_clear?(command)
    return true if command.match?(/\benv\s+-u\s+DATABASE_URL\b/i)

    command.split(/\s*&&\s*/).any? { |segment| line_clears_database_url?(segment) }
  end

  def command_has_placeholder_bracket_args?(command)
    command.scan(/\[([^\]]+)\]/) do
      return true unless Regexp.last_match(1).match?(/^\d+$/)
    end
    false
  end

  def reproduce_shell_fence_block
    lines = @doc.lines
    reproduce_idx = lines.index { |line| line.match?(/\*\*Reproduce:\*\*/) }
    return nil unless reproduce_idx

    in_fence = false
    open_marker = nil
    buffer = []
    lines.drop(reproduce_idx + 1).each do |line|
      break if line.start_with?("## ")

      if in_fence
        if fence_close?(line, open_marker)
          return buffer.join
        end
        buffer << line
      elsif (open = parse_fence_open(line))
        in_fence = true
        open_marker = open[:marker]
        buffer = []
      end
    end

    nil
  end

  def demo_line_runs_in_development?(line)
    return true if line.match?(%r{\bbin/demo[-\w]*\b})
    return true if line.match?(/\bRAILS_ENV\s*=\s*development\b/i)

    false
  end

  def shell_lines(block)
    block.lines.filter_map do |line|
      stripped = line.split("#", 2).first&.strip
      stripped if stripped && !stripped.empty?
    end
  end

  def defined_rake_tasks
    tasks = Set.new
    rake_files = Dir.glob(File.join(ROOT, "lib/tasks/*.rake")) +
                 Dir.glob(File.join(ROOT, "test/dummy/lib/tasks/*.rake"))

    rake_files.each do |path|
      namespaces = []
      namespace_open_levels = []
      block_level = 0

      File.read(path, encoding: "UTF-8").each_line do |line|
        code = line.split("#", 2).first
        stripped = code.strip

        if (m = stripped.match(/^namespace\s+:(\w+)\s+do\s*$/))
          namespaces << m[1]
          namespace_open_levels << block_level
          block_level += 1
          next
        end

        task_name = task_name_from_declaration(stripped)
        if task_name
          full_name = if task_name.include?(":")
            task_name
          else
            ([ *namespaces, task_name ].join(":"))
          end
          tasks << full_name
        end

        if rake_line_opens_block?(stripped) && !stripped.match?(/^namespace\s+/)
          block_level += 1
        end

        if stripped == "end"
          block_level -= 1
          while namespace_open_levels.any? && namespace_open_levels.last >= block_level
            namespace_open_levels.pop
            namespaces.pop
          end
        end
      end
    end

    tasks
  end

  def rake_line_opens_block?(line)
    line.match?(/\bdo\s*(\|[^|]*\|)?\s*$/)
  end

  def task_name_from_declaration(line)
    return Regexp.last_match(1) if line.match(/^task\s+"([^"]+)"/)
    return Regexp.last_match(1) if line.match(/^task\s+:(\w+)/)
    return Regexp.last_match(1) if line.match(/^task\s+(\w+):/)

    nil
  end
end
