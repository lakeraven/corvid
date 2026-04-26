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

  # -- IHS 2024 / Traditional compatibility labels ----------------------------

  test "assess result for routine includes requires_clinical_review?" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Patient needs specialist opinion",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "ROUTINE"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      # corvid_v1 always returns false for requires_clinical_review?
      # (no keyword matching — that's host-layer responsibility)
      assert_respond_to result, :requires_clinical_review?
    end
  end

  test "assess priority 2 responds to necessary?" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: true,
        medical_priority_level: nil,
        reason_for_referral: "Urgent care needed",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "URGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert result.necessary?
    end
  end

  # -- Priority assignment to PRC referral -----------------------------------

  test "assigns priority and updates referral record" do
    with_tenant(TENANT) do
      referral = create_referral_with_sr(emergent: true)
      Corvid::MedicalPriorityService.assign(referral)

      referral.reload
      assert_not_nil referral.medical_priority
      assert_equal "corvid_v1", referral.priority_system
    end
  end

  test "defaults to corvid_v1 system" do
    with_tenant(TENANT) do
      referral = create_referral_with_sr
      Corvid::MedicalPriorityService.assign(referral)

      assert_equal "corvid_v1", referral.reload.priority_system
    end
  end

  # -- Keyword detection responses -------------------------------------------

  test "assess result responds to keywords_detected" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: true, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Life-threatening stroke",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "EMERGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert_respond_to result, :keywords_detected
    end
  end

  # -- to_h includes requires_review key ------------------------------------

  test "assess result to_h includes requires_review key" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Routine evaluation",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "ROUTINE"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      hash = result.to_h
      assert hash.key?(:requires_review)
    end
  end

  # -- Funding score is numeric -----------------------------------------------

  test "funding_priority_score for urgent is 75" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: true,
        medical_priority_level: nil,
        reason_for_referral: "Urgent care",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "URGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert_equal 75, result.funding_priority_score
    end
  end

  test "funding_priority_score for routine is 50" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Routine evaluation",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "ROUTINE"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert_equal 50, result.funding_priority_score
    end
  end

  test "funding_priority_score for emergent is 100" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: true, urgent?: false,
        medical_priority_level: nil,
        reason_for_referral: "Life-threatening",
        diagnosis_codes: nil, procedure_codes: nil,
        urgency: "EMERGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert_equal 100, result.funding_priority_score
    end
  end

  # -- Priority names mapping ------------------------------------------------

  test "priority_name for urgent is Urgent/Necessary" do
    with_tenant(TENANT) do
      sr = OpenStruct.new(
        emergent?: false, urgent?: true,
        medical_priority_level: nil,
        reason_for_referral: "Urgent", diagnosis_codes: nil,
        procedure_codes: nil, urgency: "URGENT"
      )
      result = Corvid::MedicalPriorityService.assess(sr)
      assert_includes result.priority_name, "Urgent"
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
