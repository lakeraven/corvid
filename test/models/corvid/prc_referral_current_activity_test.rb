# frozen_string_literal: true

require "test_helper"
require_relative "../../support/opaque_token_check_mutants"

module Corvid
  class PrcReferralCurrentActivityTest < ActiveSupport::TestCase
    TENANT = "tnt_activity"
    FACILITY = "fac_activity"
    REVIEWER_TOKEN = "rv_01HK8B7Z9XCQVG3F8N5K0R4MWD"
    VALID_ULID_BODY = "01HK8B7Z9XCQVG3F8N5K0R4MWB"

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

    test "P1 partial load without reviewer_identifier cannot persist assigned_to_reviewer" do
      assert_activity_codes_implemented!
      referral = create_referral!(
        current_activity_code: "submitted_via_fhir_pas",
        reviewer_identifier: nil
      )
      stored_code = referral.current_activity_code
      partial = PrcReferral
        .select(*(PrcReferral.column_names - [ "reviewer_identifier" ]))
        .find(referral.id)
      partial.current_activity_code = "assigned_to_reviewer"

      refute partial.valid?
      assert_raises(StandardError) { partial.save! }
      assert_equal stored_code, referral.reload.current_activity_code
    end

    test "P1 submitted_via_fhir_pas with free-text reviewer_identifier is invalid" do
      assert_activity_codes_implemented!
      referral = build_referral(
        current_activity_code: "submitted_via_fhir_pas",
        reviewer_identifier: "Reviewer 12345"
      )
      refute referral.valid?
      assert referral.errors[:reviewer_identifier].any?
    end

    test "P1 unknown current_activity_code is invalid without surfacing the code in messages" do
      assert_activity_codes_implemented!
      referral = build_referral(current_activity_code: "unknown_code")
      refute referral.valid?
      assert referral.errors[:current_activity_code].any?
      referral.errors.full_messages.each do |message|
        refute_includes message, "unknown_code"
      end
    end

    test "P2 database CHECK rejects malformed reviewer_identifier anchors on normal schema" do
      assert_activity_codes_implemented!
      referral = create_referral!(
        current_activity_code: "assigned_to_reviewer",
        reviewer_identifier: REVIEWER_TOKEN
      )
      malformed_reviewer_anchor_tokens.each do |bad_reviewer|
        assert_reviewer_check_rejects!(referral, bad_reviewer)
      end
    end

    test "P2 database CHECK rejects malformed reviewer_identifier via insert_all" do
      assert_activity_codes_implemented!
      kase = Case.create!(patient_identifier: "pt_insert_all_#{SecureRandom.hex(2)}", facility_identifier: FACILITY)
      bad_reviewer = OpaqueTokenCheckMutants.malformed_opaque_token_anchors(prefix: "rv").first
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        PrcReferral.transaction(requires_new: true) do
          PrcReferral.insert_all(
            [ {
              tenant_identifier: TENANT,
              case_id: kase.id,
              referral_identifier: "rf_insert_all_#{SecureRandom.hex(3)}",
              facility_identifier: FACILITY,
              status: "draft",
              currency_iso: "USD",
              current_activity_code: "assigned_to_reviewer",
              reviewer_identifier: bad_reviewer,
              created_at: Time.current,
              updated_at: Time.current
            } ]
          )
        end
      end
    end

    test "P3 database CHECK rejects unknown current_activity_code via raw SQL on normal schema" do
      assert_activity_codes_implemented!
      referral = create_referral!(current_activity_code: "submitted_via_fhir_pas")
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        PrcReferral.transaction(requires_new: true) do
          db_connection.exec_update(<<~SQL)
            UPDATE corvid_prc_referrals
            SET current_activity_code = 'unknown_code'
            WHERE id = #{referral.id.to_i}
          SQL
        end
      end
      assert_equal "submitted_via_fhir_pas", referral.reload.current_activity_code
    end

    private

    def db_connection
      ActiveRecord::Base.connection
    end

    def malformed_reviewer_anchor_tokens
      OpaqueTokenCheckMutants.malformed_opaque_token_anchors(prefix: "rv")
    end

    def assert_reviewer_check_rejects!(referral, bad_reviewer)
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        PrcReferral.transaction(requires_new: true) do
          referral.update_columns(reviewer_identifier: bad_reviewer)
        end
      end
      assert_equal REVIEWER_TOKEN, referral.reload.reviewer_identifier
    end

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
