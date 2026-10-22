# frozen_string_literal: true

require "test_helper"
require "open3"

# Pins the guards on the bin/demo-* entry points (docs/demo.md). These only
# exercise paths that stop before any demo runs, so they are cheap and never
# touch a database: DATABASE_URL points at an unreachable host in case a
# guard is missing.
class DemoEntryPointsTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../../..", __dir__)
  UNREACHABLE_DB = "postgres://nobody@127.0.0.1:1/corvid_demo_guard_test"

  def run_script(script, *args, env: {})
    Open3.capture2e({ "DATABASE_URL" => UNREACHABLE_DB }.merge(env), File.join(ROOT, script), *args)
  end

  %w[bin/demo-overlay bin/demo-prc bin/demo-prc-migration].each do |script|
    test "#{script} refuses an inherited non-development RAILS_ENV" do
      output, status = run_script(script, env: { "RAILS_ENV" => "test" })

      refute status.success?, "#{script} must not run against RAILS_ENV=test"
      assert_includes output, "refusing to run with RAILS_ENV=test"
    end
  end

  test "bin/demo-smoke rejects an unknown demo name instead of reporting green" do
    output, status = run_script("bin/demo-smoke", "overlayy")

    refute status.success?, "a typo must not pass the smoke check"
    refute_includes output, "all demos green"
    assert_includes output, "unknown demo: overlayy"
  end
end
