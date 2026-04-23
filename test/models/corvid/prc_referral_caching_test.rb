# frozen_string_literal: true

require "test_helper"

class Corvid::PrcReferralCachingTest < ActiveSupport::TestCase
  TENANT = "tnt_cache_test"

  setup do
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # MEDICAL PRIORITY CACHE STALENESS
  # =============================================================================

  test "medical_priority_cached_at is nil by default" do
    with_tenant(TENANT) do
      referral = create_referral
      assert_nil referral.medical_priority_cached_at
    end
  end

  test "medical_priority_cached_at is set after assign" do
    with_tenant(TENANT) do
      referral = create_referral
      sr = OpenStruct.new(emergent?: false, urgent?: false, medical_priority_level: nil)
      referral.define_singleton_method(:service_request) { sr }

      Corvid::MedicalPriorityService.assign(referral)
      referral.reload

      assert_equal 3, referral.medical_priority
      assert_equal "corvid_v1", referral.priority_system
    end
  end

  # =============================================================================
  # AUTHORIZATION NUMBER CACHE
  # =============================================================================

  test "authorization_number is nil by default" do
    with_tenant(TENANT) do
      referral = create_referral
      assert_nil referral.authorization_number
    end
  end

  test "authorization_number is set after authorization" do
    with_tenant(TENANT) do
      referral = create_referral
      referral.update_column(:status, "committee_review")
      referral.reload

      # Register with adapter for sync
      Corvid.adapter.instance_variable_get(:@referrals)[referral.referral_identifier] = {
        patient_identifier: referral.case.patient_identifier,
        status: "pending"
      }

      referral.authorize!
      referral.reload
      assert_equal "authorized", referral.status
    end
  end

  # =============================================================================
  # ESTIMATED COST
  # =============================================================================

  test "estimated_cost stored and retrievable" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 75_000)
      referral.reload
      assert_equal 75_000, referral.estimated_cost.to_i
    end
  end

  # =============================================================================
  # REQUIRES COMMITTEE
  # =============================================================================

  test "requires_committee? true for high cost" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 60_000)
      assert referral.requires_committee?
    end
  end

  test "requires_committee? true for high priority" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 1_000, medical_priority: 3)
      assert referral.requires_committee?
    end
  end

  test "requires_committee? true when flagged" do
    with_tenant(TENANT) do
      referral = create_referral(flagged_for_review: true)
      assert referral.requires_committee?
    end
  end

  test "requires_committee? false for low cost no flags" do
    with_tenant(TENANT) do
      referral = create_referral(estimated_cost: 10_000)
      refute referral.requires_committee?
    end
  end

  private

  def create_referral(**attrs)
    c = Corvid::Case.create!(
      patient_identifier: "pt_cache_test",
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
