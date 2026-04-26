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

  # -- assess method ---------------------------------------------------------

  test "assess returns PriorityResult for emergent" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: true, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Life-threatening emergency",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "EMERGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)

      assert_equal 1, result.priority_level
      assert result.essential?
    end
  end

  test "assess returns PriorityResult for urgent" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: true,
        medical_priority_level: nil,
        reason_for_referral: "Urgent care",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "URGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)

      assert_equal 2, result.priority_level
    end
  end

  test "assess returns PriorityResult for routine" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Routine evaluation",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "ROUTINE"
      )
      result = Corvid::MedicalPriorityService.assess(sr)

      assert_equal 3, result.priority_level
    end
  end

  test "assess result responds to funding_priority_score" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: true, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Life-threatening",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "EMERGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert result.funding_priority_score >= 0
    end
  end

  test "assess result to_h includes all assessment data" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: true, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Life-threatening emergency",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "EMERGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      hash = result.to_h

      assert_equal 1, hash[:priority_level]
      assert_equal "corvid_v1", hash[:priority_system]
      assert hash.key?(:priority_name)
      assert hash.key?(:funding_score)
    end
  end

  # -- Edge cases ------------------------------------------------------------

  test "handles medical_priority_level from service request" do
    with_tenant(TENANT) do
      referral = create_referral
      sr = OpenStruct.new(
        emergent?: false, urgent?: false,
        medical_priority_level: 2
      )
      referral.define_singleton_method(:service_request) { sr }
      priority = Corvid::MedicalPriorityService.assign(referral)
      assert_equal 2, priority
    end
  end

  # -- Priority names -------------------------------------------------------

  test "priority_name for emergent is Essential" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: true, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Emergency", diagnosis_codes: nil,
        procedure_codes: nil, urgency: "EMERGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert_includes result.priority_name, "Essential"
    end
  end

  test "priority_name for routine is Routine" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Evaluation", diagnosis_codes: nil,
        procedure_codes: nil, urgency: "ROUTINE"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert_includes result.priority_name, "Routine"
    end
  end

  # -- Funding score ordering ------------------------------------------------

  test "funding priority decreases from emergent to routine" do
    with_tenant(TENANT) do
      emergent_sr = OpenStruct.new(
        emergent?: true, urgent?: false, medical_priority_level: nil,
        reason_for_referral: "Emergency", diagnosis_codes: nil,
        procedure_codes: nil, urgency: "EMERGENT"
      )
      urgent_sr = OpenStruct.new(
        emergent?: false, urgent?: true, medical_priority_level: nil,
        reason_for_referral: "Urgent", diagnosis_codes: nil,
        procedure_codes: nil, urgency: "URGENT"
      )
      routine_sr = OpenStruct.new(
        emergent?: false, urgent?: false, medical_priority_level: nil,
        reason_for_referral: "Routine", diagnosis_codes: nil,
        procedure_codes: nil, urgency: "ROUTINE"
      )

      e_score = Corvid::MedicalPriorityService.assess(emergent_sr).funding_priority_score
      u_score = Corvid::MedicalPriorityService.assess(urgent_sr).funding_priority_score
      r_score = Corvid::MedicalPriorityService.assess(routine_sr).funding_priority_score

      assert e_score >= u_score, "Emergent should have higher score than urgent"
      assert u_score >= r_score, "Urgent should have higher score than routine"
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
