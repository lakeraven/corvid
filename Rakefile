# frozen_string_literal: true

require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

# Lib-only tests don't need Rails
Rake::TestTask.new(:test_lib) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/corvid_test.rb", "test/corvid/**/*_test.rb"]
  t.verbose = false
end

# Model and integration tests use the dummy Rails app
Rake::TestTask.new(:test_models) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList[
    "test/models/**/*_test.rb",
    "test/services/**/*_test.rb",
    "test/controllers/**/*_test.rb",
    "test/rulesets/**/*_test.rb",
    "test/lib/tasks/**/*_test.rb",
    "test/lib/corvid/**/*_test.rb"
  ]
  t.verbose = false
end

# Changelog fragment tooling (tools/, changelog.d/); no Rails needed
Rake::TestTask.new(:test_tools) do |t|
  t.libs << "test"
  t.test_files = FileList["test/tools/**/*_test.rb"]
  t.verbose = false
end

task test: [ :test_lib, :test_models, :test_tools ]
load File.expand_path("tools/release_guard.rake", __dir__)

# Changelog fragments (changelog.d/): one file per PR, assembled into CHANGELOG.md at release.
namespace :changelog do
  fragments_dir = File.expand_path("changelog.d", __dir__)
  changelog = File.expand_path("CHANGELOG.md", __dir__)

  desc "Validate every changelog fragment in changelog.d/"
  task :check do
    require_relative "tools/changelog_fragments"
    puts "changelog:check: #{Fragments.check(fragments_dir)} fragment(s) valid"
  rescue Fragments::Error => e
    abort "changelog:check: #{e.message}"
  end

  desc "Insert the fragments under [Unreleased] in CHANGELOG.md and delete them (the release step commits)"
  task :assemble do
    require_relative "tools/changelog_fragments"
    result = Fragments.assemble(changelog_path: changelog, dir: fragments_dir)
    if result.files.empty?
      puts "changelog:assemble: no fragments, CHANGELOG.md unchanged"
    else
      File.write(changelog, result.text)
      File.delete(*result.files)
      puts "changelog:assemble: wrote #{result.files.size} fragment(s) into CHANGELOG.md and deleted #{result.files.map { |f| File.basename(f) }.join(', ')}"
    end
  rescue Fragments::Error => e
    abort "changelog:assemble: #{e.message}"
  end
end

task default: :test
