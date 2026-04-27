# frozen_string_literal: true

require "test_helper"

class Corvid::PrcReferralCachingTest < ActiveSupport::TestCase
  TEST_TENANT = "tnt_cache"

  setup do
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # -- helpers ---------------------------------------------------------------

  def build_referral(medical_priority: 2, authorization_number: nil)
    with_tenant(TEST_TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_cache_001")
      Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "SR#{SecureRandom.hex(4)}",
        medical_priority: medical_priority,
        authorization_number: authorization_number
      )
    end
  end

  def with_referral(**opts)
    ref = build_referral(**opts)
    with_tenant(TEST_TENANT) { yield ref.reload }
  end

  # Build a mock service_request object with given attributes
  def mock_service_request(medical_priority_level: nil, estimated_cost: nil, identifier: nil)
    sr = Object.new
    sr.define_singleton_method(:medical_priority_level) { medical_priority_level } if medical_priority_level
    sr.define_singleton_method(:estimated_cost) { estimated_cost } if estimated_cost
    sr.define_singleton_method(:identifier) { identifier } if identifier
    sr
  end

  # ==========================================================================
  # CACHE STALENESS — MEDICAL PRIORITY
  # ==========================================================================

  test "medical_priority_cache_stale? returns true when cached_at is nil" do
    with_referral do |ref|
      ref.update_columns(medical_priority_cached_at: nil)
      assert ref.medical_priority_cache_stale?
    end
  end

  test "medical_priority_cache_stale? returns true when older than threshold" do
    with_referral do |ref|
      ref.update_columns(medical_priority_cached_at: 2.hours.ago)
      assert ref.medical_priority_cache_stale?
    end
  end

  test "medical_priority_cache_stale? returns false when within threshold" do
    with_referral do |ref|
      ref.update_columns(medical_priority_cached_at: 30.minutes.ago)
      refute ref.medical_priority_cache_stale?
    end
  end

  test "medical_priority_cache_stale? returns true when exactly at threshold" do
    with_referral do |ref|
      ref.update_columns(medical_priority_cached_at: 1.hour.ago)
      assert ref.medical_priority_cache_stale?
    end
  end

  # ==========================================================================
  # CACHED_MEDICAL_PRIORITY (RCIS-FIRST PATTERN)
  # ==========================================================================

  test "cached_medical_priority returns local cache when RCIS unavailable" do
    with_referral(medical_priority: 2) do |ref|
      ref.define_singleton_method(:service_request) { nil }
      assert_equal 2, ref.cached_medical_priority
    end
  end

  test "cached_medical_priority returns RCIS value and updates cache" do
    with_referral(medical_priority: 2) do |ref|
      sr = mock_service_request(medical_priority_level: 3)
      ref.define_singleton_method(:service_request) { sr }

      result = ref.cached_medical_priority

      assert_equal 3, result
      ref.reload
      assert_equal 3, ref.medical_priority
      assert_not_nil ref.medical_priority_cached_at
    end
  end

  test "cached_medical_priority updates cache timestamp when RCIS returns value" do
    with_referral(medical_priority: 2) do |ref|
      sr = mock_service_request(medical_priority_level: 2)
      ref.define_singleton_method(:service_request) { sr }

      ref.update_columns(medical_priority_cached_at: 2.hours.ago)
      old_cached_at = ref.medical_priority_cached_at

      ref.cached_medical_priority

      ref.reload
      assert ref.medical_priority_cached_at > old_cached_at
    end
  end

  # ==========================================================================
  # REFRESH_MEDICAL_PRIORITY_FROM_RCIS!
  # ==========================================================================

  test "refresh_medical_priority_from_rcis! returns true when RCIS available" do
    with_referral(medical_priority: 2) do |ref|
      sr = mock_service_request(medical_priority_level: 4)
      ref.define_singleton_method(:service_request) { sr }

      result = ref.refresh_medical_priority_from_rcis!

      assert result
      ref.reload
      assert_equal 4, ref.medical_priority
    end
  end

  test "refresh_medical_priority_from_rcis! returns false when RCIS unavailable" do
    with_referral do |ref|
      ref.define_singleton_method(:service_request) { nil }
      refute ref.refresh_medical_priority_from_rcis!
    end
  end

  test "refresh_medical_priority_from_rcis! clears memoized service_request" do
    with_referral do |ref|
      call_count = 0
      ref.define_singleton_method(:service_request) do
        call_count += 1
        sr = Object.new
        sr.define_singleton_method(:medical_priority_level) { call_count }
        sr
      end

      ref.cached_medical_priority
      first_call_count = call_count

      ref.refresh_medical_priority_from_rcis!

      assert call_count > first_call_count, "Should have fetched fresh service_request"
    end
  end

  # ==========================================================================
  # INTEGRATION WITH REQUIRES_COMMITTEE?
  # ==========================================================================

  test "requires_committee? uses medical_priority" do
    with_referral(medical_priority: 3) do |ref|
      sr = Object.new
      sr.define_singleton_method(:estimated_cost) { nil }
      sr.define_singleton_method(:medical_priority_level) { 3 }
      ref.define_singleton_method(:service_request) { sr }
      ref.update_columns(flagged_for_review: false)

      assert ref.requires_committee?
    end
  end

  test "requires_committee? falls back to cached priority when RCIS unavailable" do
    with_referral(medical_priority: 3) do |ref|
      ref.define_singleton_method(:service_request) { nil }
      ref.update_columns(flagged_for_review: false, estimated_cost: nil)

      assert ref.requires_committee?
    end
  end

  # ==========================================================================
  # CACHE THRESHOLD CONFIGURATION
  # ==========================================================================

  test "CACHE_STALENESS_THRESHOLD_HOURS is 1 hour" do
    assert_equal 1, Corvid::PrcReferral::CACHE_STALENESS_THRESHOLD_HOURS
  end

  # ==========================================================================
  # AUTHORIZATION NUMBER CACHE STALENESS
  # ==========================================================================

  test "authorization_number_cache_stale? returns true when cached_at is nil" do
    with_referral do |ref|
      ref.update_columns(authorization_number_cached_at: nil)
      assert ref.authorization_number_cache_stale?
    end
  end

  test "authorization_number_cache_stale? returns true when older than threshold" do
    with_referral do |ref|
      ref.update_columns(authorization_number_cached_at: 2.hours.ago)
      assert ref.authorization_number_cache_stale?
    end
  end

  test "authorization_number_cache_stale? returns false when within threshold" do
    with_referral do |ref|
      ref.update_columns(authorization_number_cached_at: 30.minutes.ago)
      refute ref.authorization_number_cache_stale?
    end
  end

  # ==========================================================================
  # CACHED_AUTHORIZATION_NUMBER (RCIS-FIRST PATTERN)
  # ==========================================================================

  test "cached_authorization_number returns local cache when RCIS unavailable" do
    with_referral(authorization_number: "2025-00100") do |ref|
      ref.define_singleton_method(:service_request) { nil }
      assert_equal "2025-00100", ref.cached_authorization_number
    end
  end

  test "cached_authorization_number returns RCIS value and updates cache" do
    with_referral do |ref|
      sr = mock_service_request(identifier: "2025-00999")
      ref.define_singleton_method(:service_request) { sr }

      result = ref.cached_authorization_number

      assert_equal "2025-00999", result
      ref.reload
      assert_equal "2025-00999", ref.authorization_number
      assert_not_nil ref.authorization_number_cached_at
    end
  end

  test "cached_authorization_number updates cache timestamp when RCIS returns value" do
    with_referral(authorization_number: "2025-00100") do |ref|
      sr = mock_service_request(identifier: "2025-00100")
      ref.define_singleton_method(:service_request) { sr }

      ref.update_columns(authorization_number_cached_at: 2.hours.ago)
      old_cached_at = ref.authorization_number_cached_at

      ref.cached_authorization_number

      ref.reload
      assert ref.authorization_number_cached_at > old_cached_at
    end
  end

  # ==========================================================================
  # REFRESH_AUTHORIZATION_NUMBER_FROM_RCIS!
  # ==========================================================================

  test "refresh_authorization_number_from_rcis! returns true when RCIS available" do
    with_referral do |ref|
      sr = mock_service_request(identifier: "2025-00888")
      ref.define_singleton_method(:service_request) { sr }

      result = ref.refresh_authorization_number_from_rcis!

      assert result
      ref.reload
      assert_equal "2025-00888", ref.authorization_number
    end
  end

  test "refresh_authorization_number_from_rcis! returns false when RCIS unavailable" do
    with_referral do |ref|
      ref.define_singleton_method(:service_request) { nil }
      refute ref.refresh_authorization_number_from_rcis!
    end
  end

  # ==========================================================================
  # GENERATE_AUTHORIZATION_NUMBER (private, uses caching)
  # ==========================================================================

  test "generate_authorization_number uses cached_authorization_number" do
    with_referral do |ref|
      sr = mock_service_request(identifier: "2025-00777")
      ref.define_singleton_method(:service_request) { sr }

      result = ref.send(:generate_authorization_number)

      assert_equal "2025-00777", result
    end
  end

  test "generate_authorization_number falls back to cache when RCIS unavailable" do
    with_referral(authorization_number: "2025-00666") do |ref|
      ref.define_singleton_method(:service_request) { nil }

      result = ref.send(:generate_authorization_number)

      assert_equal "2025-00666", result
    end
  end
end
