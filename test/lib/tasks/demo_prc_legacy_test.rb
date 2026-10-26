# frozen_string_literal: true

require "test_helper"
require "rake"

# Pins demo:prc cleanup when the enrolled Case still uses the pre-#663
# underscore patient_identifier (issue #663).
class DemoPrcLegacyTest < ActiveSupport::TestCase
  TENANT = "tnt_broken_rock"
  FACILITY = "fac_broken_rock"
  CURRENT_PATIENT_ID = "pt-demo-enrolled"
  LEGACY_PATIENT_ID = "pt_demo_enrolled"
  REFERRAL_ID = "rf_broken_rock_demo"

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["demo:prc"].reenable
  end

  test "demo:prc succeeds after legacy underscore enrolled patient id and leaves one case and referral" do
    original_adapter = Corvid.adapter

    capture_io { Rake::Task["demo:prc"].invoke }

    with_tenant(TENANT) do
      updated = Corvid::Case.where(patient_identifier: CURRENT_PATIENT_ID, facility_identifier: FACILITY)
        .update_all(patient_identifier: LEGACY_PATIENT_ID)
      assert_equal 1, updated, "precondition: demo:prc seeds exactly one enrolled case"
    end

    Rake::Task["demo:prc"].reenable
    capture_io { Rake::Task["demo:prc"].invoke }

    with_tenant(TENANT) do
      assert_equal 1,
                   Corvid::Case.where(patient_identifier: CURRENT_PATIENT_ID, facility_identifier: FACILITY).count,
                   "re-run must leave exactly one demo enrolled case under the current id"
      refute Corvid::Case.exists?(patient_identifier: LEGACY_PATIENT_ID),
             "legacy underscore id must not remain after re-seed"
      assert_equal 1, Corvid::PrcReferral.where(referral_identifier: REFERRAL_ID).count
    end
  ensure
    Corvid.configure { |c| c.adapter = original_adapter }
  end
end
