# frozen_string_literal: true

# Loaded by the Rakefile only (not shipped in the gem, not loaded into host apps).
namespace :release do
  desc "Refuse to tag while changelog fragments remain in changelog.d/"
  task :changelog_guard do
    require_relative "changelog_fragments"

    pending = Fragments.pending(Fragments.release_dir)
    unless pending.empty?
      abort [ "release:changelog_guard: refusing to release: fragments are still in changelog.d/:",
              *pending.map { |n| "  #{n}" },
              "Run `rake changelog:assemble` and commit CHANGELOG.md and the deleted fragments first." ].join("\n")
    end
  end
end

# Bundler defines `release` before this file loads. The guard leads the prerequisites so
# guard_clean, the tag and the push cannot run first; the push tasks are guarded on their own
# so invoking one directly cannot skip the check.
%w[release release:source_control_push release:rubygem_push].each do |name|
  next unless Rake::Task.task_defined?(name)

  task = Rake::Task[name]
  task.enhance([ "release:changelog_guard" ])
  prereqs = task.prerequisites
  prereqs.unshift(prereqs.delete("release:changelog_guard"))
end
