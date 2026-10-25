# frozen_string_literal: true

require "test_helper"

module Corvid
  class PrcReferralCurrentActivityTest < ActiveSupport::TestCase
    TENANT = "tnt_activity"
    FACILITY = "fac_activity"
    REVIEWER_TOKEN = "rv_01HK8B7Z9XCQVG3F8N5K0R4MWD"

    setup do
      Corvid::TenantContext.current_tenant_identifier = TENANT
    end

    test "submitted_via_fhir_pas derives display text without a reviewer token" do
      assert_activity_codes_implemented!
      referral = create_referral!(
        current_activity_code: "submitted_via_fhir_pas",
        reviewer_identifier: nil
      )
      assert_equal "Submitted via FHIR PAS", referral.current_activity
      refute_includes referral.current_activity, "rv_"
    end

    test "assigned_to_reviewer derives display text without interpolating reviewer_identifier" do
      assert_activity_codes_implemented!
      referral = create_referral!(
        current_activity_code: "assigned_to_reviewer",
        reviewer_identifier: REVIEWER_TOKEN
      )
      assert_equal "Assigned to reviewer", referral.current_activity
      refute_includes referral.current_activity, REVIEWER_TOKEN
      refute_includes referral.current_activity, "456"
    end

    test "M3 assigned_to_reviewer with a non-token reviewer_identifier is invalid at the model" do
      assert_activity_codes_implemented!
      referral = build_referral(
        current_activity_code: "assigned_to_reviewer",
        reviewer_identifier: "reviewer-synthetic-001"
      )
      refute referral.valid?
      assert_includes referral.errors[:reviewer_identifier], "must be an opaque token"
    end

    test "reviewer_identifier is required when the code is assigned_to_reviewer" do
      assert_activity_codes_implemented!
      referral = build_referral(
        current_activity_code: "assigned_to_reviewer",
        reviewer_identifier: nil
      )
      refute referral.valid?
      assert referral.errors[:reviewer_identifier].any?
    end

    test "passing current_activity to create! or update! raises UnknownAttributeError" do
      assert_activity_codes_implemented!
      refute_includes PrcReferral.column_names, "current_activity",
                      "current_activity must be derived, not a database column"
      referral = create_referral!
      assert_raises(ActiveRecord::UnknownAttributeError) do
        Corvid::PrcReferral.create!(
          case: referral.case,
          referral_identifier: "rf_legacy_attr",
          facility_identifier: FACILITY,
          current_activity: "Assigned to reviewer 456"
        )
      end
      assert_raises(ActiveRecord::UnknownAttributeError) do
        referral.update!(current_activity: "Submitted via FHIR PAS")
      end
    end

    test "the database rejects an unknown current_activity_code via update_columns" do
      assert_activity_codes_implemented!
      referral = create_referral!(current_activity_code: "submitted_via_fhir_pas")
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        PrcReferral.transaction(requires_new: true) do
          referral.update_columns(current_activity_code: "bogus_code")
        end
      end
      assert_equal "submitted_via_fhir_pas", referral.reload.current_activity_code
    end

    test "M10 the database rejects assigned_to_reviewer with a NULL reviewer_identifier via update_columns" do
      assert_activity_codes_implemented!
      referral = create_referral!(
        current_activity_code: "assigned_to_reviewer",
        reviewer_identifier: REVIEWER_TOKEN
      )
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        PrcReferral.transaction(requires_new: true) do
          referral.update_columns(reviewer_identifier: nil)
        end
      end
      assert_equal REVIEWER_TOKEN, referral.reload.reviewer_identifier
    end

    test "the database rejects a non-token reviewer_identifier via update_columns" do
      assert_activity_codes_implemented!
      referral = create_referral!(
        current_activity_code: "assigned_to_reviewer",
        reviewer_identifier: REVIEWER_TOKEN
      )
      bad_reviewer = "reviewer-456"
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        PrcReferral.transaction(requires_new: true) do
          referral.update_columns(reviewer_identifier: bad_reviewer)
        end
      end
      assert_equal REVIEWER_TOKEN, referral.reload.reviewer_identifier
    end

    private

    def assert_activity_codes_implemented!
      assert_includes PrcReferral.column_names, "current_activity_code"
      assert_includes PrcReferral.column_names, "reviewer_identifier"
    end

    def create_case
      Case.create!(patient_identifier: "pt_activity", facility_identifier: FACILITY)
    end

    def build_referral(**attrs)
      PrcReferral.new(
        case: create_case,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        **attrs
      )
    end

    def create_referral!(**attrs)
      build_referral(**attrs).tap(&:save!)
    end
  end
end
