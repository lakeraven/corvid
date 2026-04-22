# frozen_string_literal: true

require "test_helper"

class Corvid::MedicalPriorityServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_mp_test"

  setup do
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  test "assigns emergent priority for emergent service request" do
    with_tenant(TENANT) do
      referral = create_referral_with_sr(emergent: true)
      priority = Corvid::MedicalPriorityService.assign(referral)

      assert_equal 1, priority
      assert_equal 1, referral.reload.medical_priority
    end
  end

  test "assigns urgent priority for urgent service request" do
    with_tenant(TENANT) do
      referral = create_referral_with_sr(urgent: true)
      priority = Corvid::MedicalPriorityService.assign(referral)

      assert_equal 2, priority
    end
  end

  test "assigns routine priority by default" do
    with_tenant(TENANT) do
      referral = create_referral_with_sr
      priority = Corvid::MedicalPriorityService.assign(referral)

      assert_equal 3, priority
    end
  end

  test "returns unknown when no service request" do
    with_tenant(TENANT) do
      referral = create_referral
      priority = Corvid::MedicalPriorityService.assign(referral)

      assert_equal :unknown, priority
    end
  end

  test "sets priority_system to corvid_v1" do
    with_tenant(TENANT) do
      referral = create_referral_with_sr
      Corvid::MedicalPriorityService.assign(referral)

      assert_equal "corvid_v1", referral.reload.priority_system
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: "pt_mp_test",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_referral
    Corvid::PrcReferral.create!(
      case: create_case,
      referral_identifier: "ref_#{SecureRandom.hex(4)}"
    )
  end

  def create_referral_with_sr(emergent: false, urgent: false)
    referral = create_referral
    # Stub service_request via adapter
    sr = OpenStruct.new(
      emergent?: emergent,
      urgent?: urgent,
      medical_priority_level: nil
    )
    referral.define_singleton_method(:service_request) { sr }
    referral
  end
end
