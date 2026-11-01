# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../tools/changelog_fragments"

# CI runs `rake test`, so validating the repo's real changelog.d/ here keeps a malformed
# fragment from merging and later blocking `rake changelog:assemble`.
class ChangelogDirectoryTest < Minitest::Test
  REAL_DIR = File.expand_path("../../changelog.d", __dir__)

  def test_every_fragment_in_the_real_changelog_d_is_valid
    count = Fragments.check(REAL_DIR)
    assert_kind_of Integer, count
  rescue Fragments::Error => e
    flunk "changelog.d is invalid (same check as rake changelog:check): #{e.message}"
  end

  def test_check_fails_on_a_directory_holding_a_bad_fragment
    Dir.mktmpdir("bad") do |dir|
      File.write(File.join(dir, "5.bogus.md"), "Heading\n")
      error = assert_raises(Fragments::Error) { Fragments.check(dir) }
      assert_includes error.message, "5.bogus.md"
    end
  end

  def test_check_counts_valid_fragments
    Dir.mktmpdir("ok") do |dir|
      File.write(File.join(dir, "5.fixed.md"), "Heading\n")
      assert_equal 1, Fragments.check(dir)
    end
  end
end
