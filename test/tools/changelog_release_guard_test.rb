# frozen_string_literal: true

require "minitest/autorun"
require "rake"
require "tmpdir"
require "fileutils"
require_relative "../../tools/changelog_fragments"

# `rake release` must not tag while fragments remain in changelog.d/ outside CHANGELOG.md.
class ChangelogReleaseGuardTest < Minitest::Test
  REPO_ROOT = File.expand_path("../..", __dir__)

  def setup
    @dir = Dir.mktmpdir("fragments")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def load_release_tasks
    @original_app = Rake.application
    Rake.application = Rake::Application.new
    Rake.application.init("rake")
    Dir.chdir(REPO_ROOT) do
      require "bundler/gem_helper"
      Bundler::GemHelper.install_tasks
      load File.join(REPO_ROOT, "tools/release_guard.rake")
    end
  end

  def restore_app
    Rake.application = @original_app
    Fragments.release_dir = nil
  end

  def test_pending_lists_every_non_ignored_file_sorted
    File.write(File.join(@dir, "9.fixed.md"), "x\n")
    File.write(File.join(@dir, "2.added.md"), "x\n")
    File.write(File.join(@dir, "README.md"), "docs\n")
    File.write(File.join(@dir, ".keep"), "")
    File.write(File.join(@dir, ".gitkeep"), "")
    assert_equal %w[2.added.md 9.fixed.md], Fragments.pending(@dir)
  end

  def test_release_refuses_while_fragments_are_pending_and_names_them
    load_release_tasks
    File.write(File.join(@dir, "12.fixed.md"), "x\n")
    File.write(File.join(@dir, "7.added.md"), "x\n")
    File.write(File.join(@dir, "README.md"), "docs\n")
    Fragments.release_dir = @dir
    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["release:changelog_guard"].invoke }
    end
    assert_includes err, "12.fixed.md"
    assert_includes err, "7.added.md"
    refute_includes err, "README.md"
    assert_includes err, "rake changelog:assemble"
    assert_match(/commit/i, err)
  ensure
    restore_app
  end

  def test_release_guard_passes_when_nothing_is_pending
    load_release_tasks
    File.write(File.join(@dir, "README.md"), "docs\n")
    File.write(File.join(@dir, ".keep"), "")
    Fragments.release_dir = @dir
    capture_io { Rake::Task["release:changelog_guard"].invoke }
  ensure
    restore_app
  end

  def test_changelog_guard_is_a_prerequisite_of_release_and_its_push_tasks
    load_release_tasks
    assert_includes Rake::Task["release"].prerequisites, "release:changelog_guard"
    assert_includes Rake::Task["release:source_control_push"].prerequisites, "release:changelog_guard"
    assert_includes Rake::Task["release:rubygem_push"].prerequisites, "release:changelog_guard"
    assert_equal "release:changelog_guard", Rake::Task["release"].prerequisites.first
  ensure
    restore_app
  end
end
