# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../tools/changelog_fragments"

# changelog.d/: one fragment file per PR, assembled under [Unreleased] at release, so two PRs
# never edit the same lines of CHANGELOG.md.
class ChangelogFragmentsTest < Minitest::Test
  CHANGELOG = <<~MD
    # Changelog

    ## [Unreleased]

    ### Changed
    - Existing entry (#1). Old body.

    ## [1.0.0] - 2026-01-01

    ### Added
    - Shipped
  MD

  def setup
    @dir = Dir.mktmpdir("fragments")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def frag(name, text)
    File.write(File.join(@dir, name), text)
  end

  def test_load_valid_fragment
    frag("12.fixed.md", "`Foo.bar` returns the row (#12)\n\n- First.\n- Second.\n")
    list = Fragments.load(@dir)
    assert_equal 1, list.size
    f = list.first
    assert_equal 12, f.id
    assert_equal "fixed", f.type
    assert_equal "`Foo.bar` returns the row (#12)", f.heading
    assert_equal "\n- First.\n- Second.\n", f.body
  end

  def test_load_ignores_readme_and_keep
    frag("README.md", "docs\n")
    frag(".keep", "")
    assert_empty Fragments.load(@dir)
  end

  def test_leading_zero_duplicate_of_same_id_and_type_is_refused
    frag("12.fixed.md", "One\n")
    frag("012.fixed.md", "Two\n")
    error = assert_raises(Fragments::Error) { Fragments.load(@dir) }
    assert_includes error.message, "012.fixed.md"
    assert_includes error.message, "12.fixed.md"
  end

  def test_hidden_fragment_is_refused_not_silently_skipped
    frag(".5.fixed.md", "Hidden\n")
    error = assert_raises(Fragments::Error) { Fragments.load(@dir) }
    assert_includes error.message, ".5.fixed.md"
  end

  def test_subdirectory_is_refused_not_silently_skipped
    FileUtils.mkdir_p(File.join(@dir, "nested"))
    File.write(File.join(@dir, "nested", "12.fixed.md"), "Nested\n")
    error = assert_raises(Fragments::Error) { Fragments.load(@dir) }
    assert_includes error.message, "nested"
  end

  def test_ds_store_and_gitkeep_are_ignored
    frag(".DS_Store", "x")
    frag(".gitkeep", "")
    assert_empty Fragments.load(@dir)
  end

  def test_bad_filename_names_the_file
    frag("notes.md", "Heading\n")
    error = assert_raises(Fragments::Error) { Fragments.load(@dir) }
    assert_includes error.message, "notes.md"
  end

  def test_non_numeric_id_is_a_bad_filename
    frag("abc.fixed.md", "Heading\n")
    error = assert_raises(Fragments::Error) { Fragments.load(@dir) }
    assert_includes error.message, "abc.fixed.md"
  end

  def test_unknown_type_names_the_file
    frag("5.tweaked.md", "Heading\n")
    error = assert_raises(Fragments::Error) { Fragments.load(@dir) }
    assert_includes error.message, "5.tweaked.md"
    assert_includes error.message, "tweaked"
  end

  def test_empty_file_names_the_file
    frag("5.fixed.md", "")
    error = assert_raises(Fragments::Error) { Fragments.load(@dir) }
    assert_includes error.message, "5.fixed.md"
  end

  def test_blank_first_line_is_a_missing_heading
    frag("5.fixed.md", "\nbody only\n")
    error = assert_raises(Fragments::Error) { Fragments.load(@dir) }
    assert_includes error.message, "5.fixed.md"
    assert_match(/heading/i, error.message)
  end

  def test_body_is_indented_under_the_bullet_and_trailing_spaces_survive
    frag("8.fixed.md", "Head (#8)\n    indented code   \n\ttabbed\t\n    last line   \n")
    assert_equal "### Fixed\n- Head (#8)\n      indented code   \n  \ttabbed\t\n      last line   \n",
                 Fragments.render(Fragments.load(@dir))
  end

  def test_blank_lines_in_the_body_stay_empty_not_indented
    frag("8.fixed.md", "Head\nfirst\n\nsecond\n")
    assert_equal "### Fixed\n- Head\n  first\n\n  second\n", Fragments.render(Fragments.load(@dir))
  end

  def test_extra_trailing_newlines_collapse_to_exactly_one
    frag("8.fixed.md", "Head\nbody\n\n\n")
    assert_equal "### Fixed\n- Head\n  body\n", Fragments.render(Fragments.load(@dir))
  end

  def test_no_trailing_newline_gets_one
    frag("8.fixed.md", "Head\nbody   ")
    assert_equal "### Fixed\n- Head\n  body   \n", Fragments.render(Fragments.load(@dir))
  end

  def test_heading_only_fragment_is_a_single_bullet
    frag("8.fixed.md", "Head only (#8)\n")
    assert_equal "### Fixed\n- Head only (#8)\n", Fragments.render(Fragments.load(@dir))
  end

  def test_render_orders_by_type_then_numeric_id_with_one_heading_per_type
    frag("10.added.md", "Ten\n")
    frag("2.added.md", "Two\n")
    frag("3.security.md", "Sec\n")
    frag("4.fixed.md", "Fix\n")
    frag("5.removed.md", "Rem\n")
    frag("6.deprecated.md", "Dep\n")
    frag("7.changed.md", "Chg\n")
    expected = "### Added\n- Two\n- Ten\n\n### Changed\n- Chg\n\n### Deprecated\n- Dep\n\n" \
               "### Removed\n- Rem\n\n### Fixed\n- Fix\n\n### Security\n- Sec\n"
    assert_equal expected, Fragments.render(Fragments.load(@dir))
  end

  def test_render_shape_matches_the_existing_bullet_entries
    frag("2.fixed.md", "Heading (#2). First sentence\ncontinues here.\n")
    assert_equal "### Fixed\n- Heading (#2). First sentence\n  continues here.\n", Fragments.render(Fragments.load(@dir))
  end

  def test_assemble_inserts_under_unreleased_before_existing_sections
    frag("7.added.md", "New thing (#7). It works.\n")
    path = File.join(@dir, "CHANGELOG.md")
    File.write(path, CHANGELOG)
    sub = File.join(@dir, "frags")
    FileUtils.mkdir_p(sub)
    FileUtils.mv(File.join(@dir, "7.added.md"), sub)
    result = Fragments.assemble(changelog_path: path, dir: sub)
    expected = CHANGELOG.sub("## [Unreleased]\n\n", "## [Unreleased]\n\n### Added\n- New thing (#7). It works.\n\n")
    assert_equal expected, result.text
    assert_equal [ File.join(sub, "7.added.md") ], result.files
    assert_operator result.text.index("New thing"), :<, result.text.index("Existing entry")
    assert_operator result.text.index("Existing entry"), :<, result.text.index("## [1.0.0]")
  end

  def test_assemble_without_fragments_returns_text_unchanged
    path = File.join(@dir, "CHANGELOG.md")
    File.write(path, CHANGELOG)
    sub = File.join(@dir, "frags")
    FileUtils.mkdir_p(sub)
    result = Fragments.assemble(changelog_path: path, dir: sub)
    assert_equal CHANGELOG, result.text
    assert_empty result.files
  end

  def test_assemble_refuses_when_unreleased_is_missing
    path = File.join(@dir, "CHANGELOG.md")
    File.write(path, "# Changelog\n\n## [1.0.0]\n")
    sub = File.join(@dir, "frags")
    FileUtils.mkdir_p(sub)
    File.write(File.join(sub, "1.added.md"), "A\n")
    error = assert_raises(Fragments::Error) { Fragments.assemble(changelog_path: path, dir: sub) }
    assert_includes error.message, "[Unreleased]"
  end

  def test_output_is_independent_of_file_creation_order
    a = Dir.mktmpdir("a")
    b = Dir.mktmpdir("b")
    begin
      File.write(File.join(a, "20.fixed.md"), "Twenty\n\nbody\n")
      File.write(File.join(a, "3.fixed.md"), "Three\n\nbody\n")
      File.write(File.join(b, "3.fixed.md"), "Three\n\nbody\n")
      File.write(File.join(b, "20.fixed.md"), "Twenty\n\nbody\n")
      assert_equal Fragments.render(Fragments.load(a)), Fragments.render(Fragments.load(b))
    ensure
      FileUtils.remove_entry(a)
      FileUtils.remove_entry(b)
    end
  end

  def test_two_branches_adding_distinct_fragments_merge_cleanly
    _, status = Open3.capture2e("git", "--version")
    skip "SKIPPED LOUDLY: git is unavailable, so the merge-conflict-freedom check did not run" unless status.success?

    repo = Dir.mktmpdir("repo")
    begin
      git = lambda do |*args|
        out, st = Open3.capture2e("git", "-C", repo, "-c", "user.name=T", "-c", "user.email=t@example.com",
                                  "-c", "commit.gpgsign=false", *args)
        assert st.success?, "git #{args.join(' ')} failed: #{out}"
        out
      end
      git.call("init", "-q", "-b", "main")
      FileUtils.mkdir_p(File.join(repo, "changelog.d"))
      File.write(File.join(repo, "CHANGELOG.md"), CHANGELOG)
      File.write(File.join(repo, "changelog.d", ".keep"), "")
      git.call("add", ".")
      git.call("commit", "-q", "-m", "base")
      git.call("checkout", "-q", "-b", "one")
      File.write(File.join(repo, "changelog.d", "101.added.md"), "One (#101)\n\n- one\n")
      git.call("add", ".")
      git.call("commit", "-q", "-m", "one")
      git.call("checkout", "-q", "main")
      git.call("checkout", "-q", "-b", "two")
      File.write(File.join(repo, "changelog.d", "102.added.md"), "Two (#102)\n\n- two\n")
      git.call("add", ".")
      git.call("commit", "-q", "-m", "two")
      git.call("checkout", "-q", "main")
      git.call("merge", "-q", "--no-edit", "one")
      git.call("merge", "-q", "--no-edit", "two")
      result = Fragments.assemble(changelog_path: File.join(repo, "CHANGELOG.md"), dir: File.join(repo, "changelog.d"))
      assert_equal 2, result.files.size
      assert_operator result.text.index("One (#101)"), :<, result.text.index("Two (#102)")
    ensure
      FileUtils.remove_entry(repo)
    end
  end

  # --- crash safety, line endings, section spacing -------------------------------------------

  def setup_release(frags)
    @sub = File.join(@dir, "frags")
    FileUtils.mkdir_p(@sub)
    frags.each { |name, text| File.write(File.join(@sub, name), text) }
    @path = File.join(@dir, "CHANGELOG.md")
    File.write(@path, CHANGELOG)
  end

  def test_apply_writes_changelog_and_deletes_fragments
    setup_release("7.added.md" => "New thing (#7)\n", "8.fixed.md" => "Bug (#8)\n")
    result = Fragments.apply(changelog_path: @path, dir: @sub)
    assert_equal 2, result.files.size
    assert_includes File.read(@path), "New thing (#7)"
    assert_includes File.read(@path), "Bug (#8)"
    assert_empty Dir.children(@sub)
    assert_equal [ "CHANGELOG.md", "frags" ], Dir.children(@dir).sort, "no temp file may be left behind"
  end

  # Design: delete the fragments into memory first, restore them if anything later fails.
  def test_apply_failing_at_the_delete_step_changes_nothing
    setup_release("7.added.md" => "New thing (#7)\n", "8.fixed.md" => "Bug (#8)\n")
    real_delete = File.method(:delete)
    calls = 0
    flaky = lambda do |*paths|
      calls += 1
      raise Errno::EACCES, "simulated delete failure" if calls == 2

      real_delete.call(*paths)
    end
    assert_raises(Errno::EACCES) { Fragments.apply(changelog_path: @path, dir: @sub, deleter: flaky) }
    assert_equal CHANGELOG, File.read(@path), "CHANGELOG.md must be untouched"
    assert_equal [ "7.added.md", "8.fixed.md" ], Dir.children(@sub).sort, "every fragment must be restored"
    assert_equal "New thing (#7)\n", File.read(File.join(@sub, "7.added.md"))
    assert_equal [ "CHANGELOG.md", "frags" ], Dir.children(@dir).sort, "no temp file may be left behind"
    # a re-run after the failure assembles exactly once
    Fragments.apply(changelog_path: @path, dir: @sub)
    assert_equal 1, File.read(@path).scan("New thing (#7)").size
    assert_empty Dir.children(@sub)
  end

  def test_apply_failing_at_the_rename_step_restores_the_fragments
    setup_release("7.added.md" => "New thing (#7)\n")
    failing = ->(*) { raise Errno::EIO, "simulated rename failure" }
    assert_raises(Errno::EIO) { Fragments.apply(changelog_path: @path, dir: @sub, renamer: failing) }
    assert_equal CHANGELOG, File.read(@path)
    assert_equal [ "7.added.md" ], Dir.children(@sub)
    assert_equal [ "CHANGELOG.md", "frags" ], Dir.children(@dir).sort
  end

  def test_crlf_fragments_render_with_no_carriage_returns
    frag("9.fixed.md", "Fix\r\nbody\r\n\r\nmore\r\n")
    out = Fragments.render(Fragments.load(@dir))
    refute_includes out, "\r"
    assert_equal "### Fixed\n- Fix\n  body\n\n  more\n", out
  end

  def test_assemble_leaves_one_blank_line_when_unreleased_is_followed_directly_by_a_heading
    setup_release("7.added.md" => "New thing (#7)\n")
    File.write(@path, "# Changelog\n\n## [Unreleased]\n### Changed\n- Existing\n\n## [1.0.0]\n")
    out = Fragments.assemble(changelog_path: @path, dir: @sub).text
    assert_match(/New thing \(#7\)[^\n]*\n(\n|(?:[^\n]*\n)*\n)### Changed\n/, out)
    assert_includes out, "\n\n### Changed\n- Existing\n"
    refute_match(/\n\n\n/, out)
  end

  def test_assemble_leaves_exactly_one_blank_line_when_several_blank_lines_follow_unreleased
    setup_release("7.added.md" => "New thing (#7)\n")
    File.write(@path, "# Changelog\n\n## [Unreleased]\n\n\n\n### Changed\n- Existing\n")
    out = Fragments.assemble(changelog_path: @path, dir: @sub).text
    refute_match(/\n\n\n/, out)
    assert_includes out, "\n\n### Changed\n- Existing\n"
  end

  def test_assemble_when_unreleased_is_the_last_section
    setup_release("7.added.md" => "New thing (#7)\n")
    File.write(@path, "# Changelog\n\n## [Unreleased]\n")
    out = Fragments.assemble(changelog_path: @path, dir: @sub).text
    assert out.end_with?("New thing (#7)\n"), out.inspect
  end
end
