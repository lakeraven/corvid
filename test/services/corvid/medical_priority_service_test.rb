# frozen_string_literal: true

require "test_helper"

class Corvid::MedicalPriorityServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_mp_test"

  setup do
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # IHS 2024 PRIORITY SYSTEM (1-4)
  # =============================================================================

  test "IHS 2024: Priority 1 Essential for life-threatening emergency" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "EMERGENT",
        reason_for_referral: "Severe chest pain, suspected myocardial infarction, life-threatening",
        priority_system: "ihs_2024"
      )

      assert_equal 1, result.priority_level
      assert_includes result.priority_name, "Essential"
      assert result.essential?
    end
  end

  test "IHS 2024: Priority 2 Necessary for chronic disease management" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "ROUTINE",
        reason_for_referral: "Chronic diabetes management, follow-up care",
        priority_system: "ihs_2024"
      )

      assert_equal 2, result.priority_level
      assert_includes result.priority_name, "Necessary"
      assert result.necessary?
    end
  end

  test "IHS 2024: Priority 3 Justifiable for preventive care" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "ROUTINE",
        reason_for_referral: "Annual screening mammogram, preventive care",
        priority_system: "ihs_2024"
      )

      assert_equal 3, result.priority_level
      assert_includes result.priority_name, "Justifiable"
      assert result.justifiable?
    end
  end

  test "IHS 2024: Priority 4 Excluded for cosmetic procedures" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "ROUTINE",
        reason_for_referral: "Cosmetic rhinoplasty, not covered",
        priority_system: "ihs_2024"
      )

      assert_equal 4, result.priority_level
      assert_includes result.priority_name, "Excluded"
      assert result.excluded?
    end
  end

  test "IHS 2024: defaults to Justifiable (3) when no keywords match" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "ROUTINE",
        reason_for_referral: "General evaluation needed",
        priority_system: "ihs_2024"
      )

      assert_equal 3, result.priority_level
      assert result.requires_clinical_review?
    end
  end

  # =============================================================================
  # SIMPLE ASSIGN (existing API)
  # =============================================================================

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

  # =============================================================================
  # FUNDING PRIORITY SCORING
  # =============================================================================

  test "IHS 2024: Essential (1) has highest funding score" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "EMERGENT",
        reason_for_referral: "Life-threatening emergency",
        priority_system: "ihs_2024"
      )

      assert_equal 100, result.funding_priority_score
    end
  end

  test "IHS 2024: Excluded (4) has zero funding score" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "ROUTINE",
        reason_for_referral: "Cosmetic procedure, not covered",
        priority_system: "ihs_2024"
      )

      assert_equal 0, result.funding_priority_score
    end
  end

  test "IHS 2024 funding priority decreases from 1 to 4" do
    with_tenant(TENANT) do
      reasons = {
        1 => ["EMERGENT", "Life-threatening cardiac arrest"],
        2 => ["ROUTINE", "Chronic diabetes management"],
        3 => ["ROUTINE", "Preventive screening"],
        4 => ["ROUTINE", "Cosmetic procedure excluded"]
      }

      scores = reasons.map do |_priority, (urgency, reason)|
        assess_service_request(
          urgency: urgency,
          reason_for_referral: reason,
          priority_system: "ihs_2024"
        ).funding_priority_score
      end

      scores.each_cons(2) do |higher, lower|
        assert higher >= lower, "Priority scores should decrease: #{higher} >= #{lower}"
      end
    end
  end

  # =============================================================================
  # CLINICAL REVIEW FLAGGING
  # =============================================================================

  test "flags for clinical review when no keywords match" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "ROUTINE",
        reason_for_referral: "Patient needs specialist opinion",
        priority_system: "ihs_2024"
      )

      assert result.requires_clinical_review?
    end
  end

  test "does not flag for review when keywords match" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "EMERGENT",
        reason_for_referral: "Life-threatening cardiac emergency",
        priority_system: "ihs_2024"
      )

      refute result.requires_clinical_review?
    end
  end

  # =============================================================================
  # ASSESSMENT TO HASH
  # =============================================================================

  test "to_h includes all assessment data" do
    with_tenant(TENANT) do
      result = assess_service_request(
        urgency: "EMERGENT",
        reason_for_referral: "Life-threatening cardiac emergency",
        priority_system: "ihs_2024"
      )
      hash = result.to_h

      assert_equal 1, hash[:priority_level]
      assert_equal "ihs_2024", hash[:priority_system]
      assert_includes hash[:priority_name], "Essential"
      assert_equal 100, hash[:funding_score]
      assert_equal false, hash[:requires_review]
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
    sr = OpenStruct.new(
      emergent?: emergent,
      urgent?: urgent,
      medical_priority_level: nil,
      reason_for_referral: "Test referral",
      urgency: emergent ? "EMERGENT" : (urgent ? "URGENT" : "ROUTINE")
    )
    referral.define_singleton_method(:service_request) { sr }
    referral
  end

  def assess_service_request(urgency:, reason_for_referral:, priority_system:)
    sr = OpenStruct.new(
      urgency: urgency,
      reason_for_referral: reason_for_referral,
      emergent?: urgency == "EMERGENT",
      urgent?: urgency == "URGENT",
      routine?: urgency == "ROUTINE",
      diagnosis_codes: nil,
      procedure_codes: nil,
      medical_priority_level: nil
    )

    Corvid::MedicalPriorityService.assess(sr, priority_system: priority_system)
  end
end
