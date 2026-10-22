# frozen_string_literal: true

require "test_helper"
require "rake"

# Pins demo:overlay_reset (lib/tasks/demo_fhir_overlay.rake). The overlay and
# the narrated PRC demo share the Broken Rock tenant/facility, so the overlay
# reset must clear whatever demo:prc left there — including the twelve
# alternate-resource checks it now seeds — or running the demos in a
# different order breaks `bin/demo-overlay`.
class DemoOverlayRakeTest < ActiveSupport::TestCase
  TENANT = "tnt_broken_rock"
  FACILITY = "fac_broken_rock"

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["demo:prc"].reenable
    Rake::Task["demo:overlay_reset"].reenable
  end

  test "demo:overlay_reset clears a referral demo:prc left with alternate-resource checks" do
    original_adapter = Corvid.adapter
    capture_io { Rake::Task["demo:prc"].invoke }

    check_ids = with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      Corvid::AlternateResourceCheck.joins(:prc_referral)
        .merge(Corvid::PrcReferral.for_facility(FACILITY)).pluck(:id)
    end
    assert_not_empty check_ids, "precondition: demo:prc seeds alternate-resource checks in the shared facility"

    capture_io { Rake::Task["demo:overlay_reset"].invoke }

    with_tenant(TENANT) do
      assert_equal 0, Corvid::AlternateResourceCheck.unscoped.where(id: check_ids).count,
                   "the checks demo:prc seeded must be gone, not orphaned"
      assert_equal 0, Corvid::PrcReferral.for_facility(FACILITY).count
      assert_equal 0, Corvid::Case.for_facility(FACILITY).count
    end
  ensure
    Corvid.configure { |c| c.adapter = original_adapter }
  end
end
