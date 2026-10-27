# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 pin 3: imported or direct status writes are not
# authorization decisions — only AASM authorize / deny / defer sync and record
# provenance after commit.
module Corvid
  class PrcReferralImportedStatusSyncTest < ActiveSupport::TestCase
    TENANT = "tnt_import_sync"
    FACILITY = "fac_import_sync"
    PATIENT = "pt_import_sync"

    teardown do
      Corvid.reset_configuration!
    end

    %w[authorized denied deferred].each do |imported_status|
      test "create! already #{imported_status} does not call update_referral or on_provenance" do
        ehr_updates = []
        provenance_activities = []
        Corvid.configure do |c|
          c.on_provenance = ->(**attrs) { provenance_activities << attrs[:activity] }
        end

        with_tenant(TENANT) do
          Corvid.adapter.define_singleton_method(:update_referral) do |identifier, params|
            ehr_updates << [ identifier, params.dup ]
            true
          end

          kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
          ActiveRecord::Base.transaction do
            PrcReferral.create!(
              case: kase,
              referral_identifier: "REF-IMPORT-#{imported_status}-#{SecureRandom.hex(2)}",
              facility_identifier: FACILITY,
              tenant_identifier: TENANT,
              status: imported_status
            )
          end
        end

        assert_empty ehr_updates,
          "imported #{imported_status} referral must not sync to EHR, got #{ehr_updates.inspect}"
        assert_empty provenance_activities,
          "imported #{imported_status} referral must not record provenance, got #{provenance_activities.inspect}"
      end
    end

    test "plain update! to authorized on existing referral does not sync or record provenance" do
      ehr_updates = []
      provenance_activities = []
      Corvid.configure do |c|
        c.on_provenance = ->(**attrs) { provenance_activities << attrs[:activity] }
      end

      with_tenant(TENANT) do
        Corvid.adapter.define_singleton_method(:update_referral) do |identifier, params|
          ehr_updates << [ identifier, params.dup ]
          true
        end

        kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
        referral = PrcReferral.create!(
          case: kase,
          referral_identifier: "REF-DIRECT-#{SecureRandom.hex(2)}",
          facility_identifier: FACILITY,
          tenant_identifier: TENANT
        )

        ActiveRecord::Base.transaction do
          referral.update!(status: "authorized")
        end
      end

      assert_empty ehr_updates,
        "direct status write must not sync to EHR, got #{ehr_updates.inspect}"
      assert_empty provenance_activities,
        "direct status write must not record provenance, got #{provenance_activities.inspect}"
    end
  end
end
