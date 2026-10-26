# frozen_string_literal: true

require "test_helper"
require "rake"
require "open3"

# Pins the RAILS_ENV guard on the demo:* rake tasks. The bin/demo-* entry
# points already refuse anything but development (demo_entry_points_test.rb),
# but the tasks can be run directly, and each one deletes and re-seeds rows.
# Run under RAILS_ENV=test they would write into the test database, so they
# must refuse before touching it.
class DemoEnvironmentGuardTest < ActiveSupport::TestCase
  DEMO_TASKS = %w[
    demo:prc
    demo:mlr_savings
    demo:overlay
    demo:overlay_reset
    demo:migrate
    demo:migration_reset
  ].freeze

  # Every table demo:mlr_savings deletes from and re-seeds.
  MLR_SEEDED_MODELS = [
    Corvid::FeeScheduleEntry,
    Corvid::IppsDrgWeight,
    Corvid::IppsHospitalRate,
    Corvid::OppsApcWeight,
    Corvid::OppsConversionFactor
  ].freeze

  DUMMY_APP = File.expand_path("../../dummy", __dir__)
  UNREACHABLE_DB = "postgres://nobody@127.0.0.1:1/corvid_demo_guard_test"

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  test "every demo task is guarded" do
    defined = Rake::Task.tasks.map(&:name).grep(/\Ademo:/)

    assert_equal DEMO_TASKS.sort, defined.sort,
                 "a new demo:* task must call Corvid::Demo::EnvironmentGuard and be listed here"
  end

  DEMO_TASKS.each do |name|
    test "#{name} refuses to run outside development" do
      Rake::Task[name].reenable

      error = nil
      _out, err = capture_io do
        error = assert_raises(SystemExit) { Rake::Task[name].invoke }
      end

      refute error.success?, "#{name} must exit non-zero under RAILS_ENV=test"
      assert_includes err, "#{name}: refusing to run with RAILS_ENV=test; the demos use development"
    end
  end

  test "demo:mlr_savings writes no rows when it refuses" do
    Rake::Task["demo:mlr_savings"].reenable
    before = MLR_SEEDED_MODELS.to_h { |model| [ model.name, model.count ] }

    capture_io do
      assert_raises(SystemExit) { Rake::Task["demo:mlr_savings"].invoke }
    end

    after = MLR_SEEDED_MODELS.to_h { |model| [ model.name, model.count ] }
    assert_equal before, after, "the guard must stop the task before it deletes or seeds anything"
  end

  # The command the issue reported, end to end. DATABASE_URL points at an
  # unreachable host so that, were the guard missing, the run would fail on
  # connect rather than write anywhere; the message assertion tells the two apart.
  test "bin/rails demo:mlr_savings under RAILS_ENV=test refuses" do
    output, status = Open3.capture2e(
      { "RAILS_ENV" => "test", "DATABASE_URL" => UNREACHABLE_DB },
      "bin/rails", "demo:mlr_savings",
      chdir: DUMMY_APP
    )

    refute status.success?
    assert_includes output, "demo:mlr_savings: refusing to run with RAILS_ENV=test; the demos use development"
  end
end
