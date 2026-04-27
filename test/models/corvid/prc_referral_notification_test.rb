# frozen_string_literal: true

require "test_helper"

class Corvid::PrcReferralNotificationTest < ActiveSupport::TestCase
  TEST_TENANT = "tnt_notif"

  setup do
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # -- helpers ---------------------------------------------------------------

  def build_referral(emergency: false, notification_date: nil, status: "draft")
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_notif_001")
      Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "SR#{SecureRandom.hex(4)}",
        emergency_flag: emergency,
        notification_date: notification_date,
        status: status
      )
    end
  end

  def with_referral(**opts)
    ref = build_referral(**opts)
    with_tenant(TEST_TENANT) { yield ref.reload }
  end

  def mock_adapter_with(grace_period: 72)
    mock = Object.new
    mock.define_singleton_method(:get_site_params) { { notification_grace_period: grace_period } }
    mock.define_singleton_method(:store_text) { |**_| "token-#{SecureRandom.hex(4)}" }
    mock.define_singleton_method(:update_referral) { |*_| true }
    mock.define_singleton_method(:find_referral) { |*_| nil }
    original = Corvid.adapter
    Corvid.configure { |c| c.adapter = mock }
    yield
  ensure
    Corvid.configure { |c| c.adapter = original }
  end

  # ==========================================================================
  # NOTIFICATION STATUS
  # ==========================================================================

  test "notification_status returns timely when within 72 hours" do
    with_referral(emergency: true, notification_date: 48.hours.ago) do |ref|
      assert_equal "timely", ref.notification_status
    end
  end

  test "notification_status returns timely at exactly 72 hours" do
    with_referral(emergency: true, notification_date: 72.hours.ago) do |ref|
      assert_equal "timely", ref.notification_status
    end
  end

  test "notification_status returns late after 72 hours" do
    with_referral(emergency: true, notification_date: 73.hours.ago) do |ref|
      assert_equal "late", ref.notification_status
    end
  end

  test "notification_status returns not_required for non-emergency" do
    with_referral(emergency: false, notification_date: 100.hours.ago) do |ref|
      assert_equal "not_required", ref.notification_status
    end
  end

  test "notification_status returns missing when emergency has no date" do
    with_referral(emergency: true, notification_date: nil) do |ref|
      assert_equal "missing", ref.notification_status
    end
  end

  # ==========================================================================
  # CONFIGURABLE GRACE PERIOD
  # ==========================================================================

  test "uses adapter-configured grace period" do
    with_referral(emergency: true, notification_date: 80.hours.ago) do |ref|
      mock_adapter_with(grace_period: 96) do
        assert_equal "timely", ref.notification_status
      end
    end
  end

  test "uses default 72-hour grace period when not configured" do
    with_referral(emergency: true, notification_date: 73.hours.ago) do |ref|
      assert_equal "late", ref.notification_status
      assert_equal 72, ref.notification_grace_period
    end
  end

  test "shorter grace period makes timely notification late" do
    with_referral(emergency: true, notification_date: 60.hours.ago) do |ref|
      mock_adapter_with(grace_period: 48) do
        assert_equal "late", ref.notification_status
      end
    end
  end

  # ==========================================================================
  # HOURS CALCULATION
  # ==========================================================================

  test "hours_since_notification calculates correctly" do
    with_referral(notification_date: 48.hours.ago) do |ref|
      assert_in_delta 48, ref.hours_since_notification, 1
    end
  end

  test "hours_since_notification returns nil when no date" do
    with_referral(notification_date: nil) do |ref|
      assert_nil ref.hours_since_notification
    end
  end

  # ==========================================================================
  # EXCEPTION REVIEW REQUIREMENTS
  # ==========================================================================

  test "requires_exception_review? is true for late notifications" do
    with_referral(emergency: true, notification_date: 100.hours.ago) do |ref|
      assert ref.requires_exception_review?
    end
  end

  test "requires_exception_review? is true for missing notification date" do
    with_referral(emergency: true, notification_date: nil) do |ref|
      assert ref.requires_exception_review?
    end
  end

  test "requires_exception_review? is false for timely notifications" do
    with_referral(emergency: true, notification_date: 24.hours.ago) do |ref|
      refute ref.requires_exception_review?
    end
  end

  test "requires_exception_review? is false for non-emergency" do
    with_referral(emergency: false, notification_date: nil) do |ref|
      refute ref.requires_exception_review?
    end
  end

  # ==========================================================================
  # LATE NOTIFICATION DOCUMENTATION
  # ==========================================================================

  test "document_late_notification! records reason token and timestamp" do
    with_referral(emergency: true, notification_date: 100.hours.ago) do |ref|
      ref.document_late_notification!(
        reason: "Patient was at remote facility",
        documented_by: "pract_101"
      )

      ref.reload
      assert ref.late_notification_reason_token.present?
      assert_not_nil ref.late_notification_documented_at
      assert_equal "pract_101", ref.late_notification_documented_by_identifier
    end
  end

  test "document_late_notification! requires reason keyword" do
    with_referral(emergency: true, notification_date: 100.hours.ago) do |ref|
      assert_raises(ArgumentError) do
        ref.document_late_notification!(documented_by: "pract_101")
      end
    end
  end

  # ==========================================================================
  # EXCEPTION REVIEW APPROVAL
  # ==========================================================================

  test "approve_exception_review! records approval fields" do
    with_referral(emergency: true, notification_date: 100.hours.ago) do |ref|
      ref.document_late_notification!(reason: "Test reason", documented_by: "pract_101")

      ref.approve_exception_review!(rationale: "Justified delay", approved_by: "pract_102")

      ref.reload
      assert ref.exception_approved?
      assert ref.exception_rationale_token.present?
      assert_not_nil ref.exception_reviewed_at
      assert_equal "pract_102", ref.exception_reviewed_by_identifier
    end
  end

  # ==========================================================================
  # EXCEPTION REVIEW DENIAL
  # ==========================================================================

  test "deny_exception_review! records denial and creates determination" do
    ref = nil
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_deny_001")
      ref = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "SR#{SecureRandom.hex(4)}",
        emergency_flag: true,
        notification_date: 100.hours.ago,
        status: "exception_review"
      )
    end

    with_tenant(TEST_TENANT) do
      ref = ref.reload
      ref.document_late_notification!(reason: "Test reason", documented_by: "pract_101")

      ref.deny_exception_review!(rationale: "No valid justification", denied_by: "pract_102")

      ref.reload
      assert_equal "denied", ref.status

      determination = ref.determinations.last
      assert_not_nil determination
      assert_equal "denied", determination.outcome
    end
  end

  test "deny_exception_review! transitions to denied when allowed" do
    ref = nil
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_deny_002")
      ref = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "SR#{SecureRandom.hex(4)}",
        emergency_flag: true,
        notification_date: 100.hours.ago,
        status: "exception_review"
      )
    end

    with_tenant(TEST_TENANT) do
      ref = ref.reload
      ref.document_late_notification!(reason: "Test reason", documented_by: "pract_101")

      ref.deny_exception_review!(rationale: "No justification", denied_by: "pract_102")

      ref.reload
      assert_equal "denied", ref.status
    end
  end

  # ==========================================================================
  # NOTIFICATION WITHIN 72 HOURS (convenience method)
  # ==========================================================================

  test "notification_within_72_hours? returns true when timely" do
    with_referral(emergency: true, notification_date: 48.hours.ago) do |ref|
      assert ref.notification_within_72_hours?
    end
  end

  test "notification_within_72_hours? returns false when late" do
    with_referral(emergency: true, notification_date: 100.hours.ago) do |ref|
      refute ref.notification_within_72_hours?
    end
  end

  test "notification_within_72_hours? returns true for non-emergency" do
    with_referral(emergency: false, notification_date: nil) do |ref|
      assert ref.notification_within_72_hours?
    end
  end
end
