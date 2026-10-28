# frozen_string_literal: true

require "test_helper"
require "rake"

# Pins demo:prc (lib/tasks/demo.rake) so the narrated happy path seeds all
# twelve alternate-resource determinations before guarded authorization steps.
class DemoPrcRakeTest < ActiveSupport::TestCase
  TENANT = "tnt_broken_rock"
  FACILITY = "fac_broken_rock"
  PATIENT_ID = "pt_demo_enrolled"
  REFERRAL_ID = "rf_broken_rock_demo"

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["demo:prc"].reenable
  end

  test "demo:prc leaves referral authorized with all alternate resources exhausted" do
    original_adapter = Corvid.adapter

    capture_io { Rake::Task["demo:prc"].invoke }

    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      referral = Corvid::PrcReferral.find_by!(referral_identifier: REFERRAL_ID)

      exhaust_alternate_resources!(referral, date_of_service: Date.current, as_of: Time.current)
      referral.verify_alternate_resources! if referral.may_verify_alternate_resources?
      if referral.may_complete_priority_assignment?
        referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: referral.estimated_cost || 5_000)
        referral.complete_priority_assignment!
      end
      referral.authorize! if referral.may_authorize?

      assert_equal "authorized", referral.reload.status,
                   "demo cost is below committee threshold; referral should authorize when checks are seeded"
      assert Corvid::AlternateResourceCheck.all_exhausted?(referral),
             "demo must seed all twelve payer determinations; Medicaid needs inquiry_date_of_service (issue #712)"
      assert_equal Corvid::AlternateResourceCheck::RESOURCE_TYPES.size,
                   referral.alternate_resource_checks.count
    end
  ensure
    Corvid.configure { |c| c.adapter = original_adapter }
  end
end
