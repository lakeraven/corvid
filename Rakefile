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
  t.test_files = FileList["test/models/**/*_test.rb", "test/services/**/*_test.rb"]
  t.verbose = false
end

task test: [ :test_lib, :test_models ]
task default: :test
