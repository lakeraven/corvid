# frozen_string_literal: true

require "test_helper"

class Corvid::PrcReferralNotificationTest < ActiveSupport::TestCase
  TENANT = "tnt_notif_test"

  setup do
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # NOTIFICATION STATUS
  # =============================================================================

  test "notification_status returns timely when within 72 hours" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 48.hours.ago)
      assert_equal "timely", referral.notification_status
    end
  end

  test "notification_status returns timely at exactly 72 hours" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 72.hours.ago)
      assert_equal "timely", referral.notification_status
    end
  end

  test "notification_status returns late after 72 hours" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 73.hours.ago)
      assert_equal "late", referral.notification_status
    end
  end

  test "notification_status returns not_required for non-emergency" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: false, notification_date: 100.hours.ago)
      assert_equal "not_required", referral.notification_status
    end
  end

  test "notification_status returns missing when emergency has no date" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: nil)
      assert_equal "missing", referral.notification_status
    end
  end

  # =============================================================================
  # HOURS CALCULATION
  # =============================================================================

  test "hours_since_notification calculates correctly" do
    with_tenant(TENANT) do
      referral = create_referral(notification_date: 48.hours.ago)
      assert_in_delta 48, referral.hours_since_notification, 1
    end
  end

  test "hours_since_notification returns nil when no date" do
    with_tenant(TENANT) do
      referral = create_referral(notification_date: nil)
      assert_nil referral.hours_since_notification
    end
  end

  # =============================================================================
  # EXCEPTION REVIEW REQUIREMENTS
  # =============================================================================

  test "requires_exception_review? is true for late notifications" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 100.hours.ago)
      assert referral.requires_exception_review?
    end
  end

  test "requires_exception_review? is true for missing notification date" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: nil)
      assert referral.requires_exception_review?
    end
  end

  test "requires_exception_review? is false for timely notifications" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 24.hours.ago)
      refute referral.requires_exception_review?
    end
  end

  test "requires_exception_review? is false for non-emergency" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: false, notification_date: nil)
      refute referral.requires_exception_review?
    end
  end

  # =============================================================================
  # LATE NOTIFICATION DOCUMENTATION
  # =============================================================================

  test "document_late_notification! records timestamp" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 100.hours.ago)
      referral.document_late_notification!(
        reason: "Patient was at remote facility",
        documented_by: "pr_101"
      )
      referral.reload
      assert_not_nil referral.late_notification_documented_at
      assert_equal "pr_101", referral.late_notification_documented_by_identifier
    end
  end

  # =============================================================================
  # EXCEPTION REVIEW APPROVAL
  # =============================================================================

  test "approve_exception_review! records approval" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 100.hours.ago)
      referral.approve_exception_review!(
        rationale: "Justified delay",
        approved_by: "pr_102"
      )
      referral.reload
      assert referral.exception_approved?
      assert_not_nil referral.exception_reviewed_at
      assert_equal "pr_102", referral.exception_reviewed_by_identifier
    end
  end

  # =============================================================================
  # EXCEPTION REVIEW DENIAL
  # =============================================================================

  test "deny_exception_review! records denial" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 100.hours.ago)
      referral.update_column(:status, "exception_review")
      referral.reload

      referral.deny_exception_review!(
        rationale: "No valid justification",
        denied_by: "pr_102"
      )
      referral.reload
      assert_equal false, referral.exception_approved
      assert_equal "denied", referral.status
    end
  end

  test "deny_exception_review! creates determination" do
    with_tenant(TENANT) do
      referral = create_referral(emergency_flag: true, notification_date: 100.hours.ago)
      referral.update_column(:status, "exception_review")
      referral.reload

      referral.deny_exception_review!(
        rationale: "No valid justification",
        denied_by: "pr_102"
      )

      determination = referral.determinations.last
      assert_not_nil determination
      assert_equal "denied", determination.outcome
    end
  end

  # =============================================================================
  # GRACE PERIOD
  # =============================================================================

  test "notification_grace_period defaults to 72" do
    with_tenant(TENANT) do
      referral = create_referral
      assert_equal 72, referral.notification_grace_period
    end
  end

  private

  def create_referral(**attrs)
    c = Corvid::Case.create!(
      patient_identifier: "pt_notif_test",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
    Corvid::PrcReferral.create!(
      case: c,
      referral_identifier: "ref_#{SecureRandom.hex(4)}",
      **attrs
    )
  end
end
