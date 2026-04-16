# frozen_string_literal: true

require "test_helper"
require "corvid/rules_engine"

class Corvid::PrcEligibilityRulesetTest < ActiveSupport::TestCase
  setup do
    @ruleset = Corvid::PrcEligibilityRuleset.new
    @engine = Corvid::RulesEngine.new(@ruleset)
  end

  # === TRIBAL ENROLLMENT ===

  test "is_tribally_enrolled passes with valid format" do
    @engine.set_facts(enrollment_number: "ANLC-12345")
    assert @engine.evaluate(:is_tribally_enrolled).value
  end

  test "is_tribally_enrolled passes with different tribe codes" do
    %w[ANLC-123 TCC-999 CIRI-10000 AHTNA-1].each do |number|
      engine = Corvid::RulesEngine.new(Corvid::PrcEligibilityRuleset.new)
      engine.set_facts(enrollment_number: number)
      assert engine.evaluate(:is_tribally_enrolled).value, "Expected #{number} to be valid"
    end
  end

  test "is_tribally_enrolled fails with missing prefix" do
    @engine.set_facts(enrollment_number: "12345")
    assert_equal false, @engine.evaluate(:is_tribally_enrolled).value
  end

  test "is_tribally_enrolled fails with lowercase" do
    @engine.set_facts(enrollment_number: "anlc-12345")
    assert_equal false, @engine.evaluate(:is_tribally_enrolled).value
  end

  test "is_tribally_enrolled fails with nil" do
    @engine.set_facts(enrollment_number: nil)
    assert_equal false, @engine.evaluate(:is_tribally_enrolled).value
  end

  test "is_tribally_enrolled fails with empty string" do
    @engine.set_facts(enrollment_number: "")
    assert_equal false, @engine.evaluate(:is_tribally_enrolled).value
  end

  # === RESIDENCY ===

  test "meets_residency passes for all valid service areas" do
    Corvid::PrcEligibilityRuleset::VALID_SERVICE_AREAS.each do |area|
      engine = Corvid::RulesEngine.new(Corvid::PrcEligibilityRuleset.new)
      engine.set_facts(service_area: area)
      assert engine.evaluate(:meets_residency).value, "Expected #{area} to be valid"
    end
  end

  test "meets_residency fails for invalid service area" do
    @engine.set_facts(service_area: "Seattle")
    assert_equal false, @engine.evaluate(:meets_residency).value
  end

  test "meets_residency fails for nil" do
    @engine.set_facts(service_area: nil)
    assert_equal false, @engine.evaluate(:meets_residency).value
  end

  # === CLINICAL JUSTIFICATION ===

  test "has_clinical_justification passes with clinical keywords" do
    ["chest pain", "cardiac evaluation", "surgery consultation", "fracture treatment",
     "severe headache", "chronic condition", "failed treatment"].each do |reason|
      engine = Corvid::RulesEngine.new(Corvid::PrcEligibilityRuleset.new)
      engine.set_facts(reason_for_referral: reason)
      assert engine.evaluate(:has_clinical_justification).value, "Expected '#{reason}' to pass"
    end
  end

  test "has_clinical_justification fails without keywords" do
    @engine.set_facts(reason_for_referral: "Patient wants to see specialist")
    assert_equal false, @engine.evaluate(:has_clinical_justification).value
  end

  test "has_clinical_justification fails with nil" do
    @engine.set_facts(reason_for_referral: nil)
    assert_equal false, @engine.evaluate(:has_clinical_justification).value
  end

  # === URGENCY ===

  test "urgency_appropriate passes for routine with justification" do
    @engine.set_facts(reason_for_referral: "Chronic condition needs evaluation", urgency: :routine)
    assert @engine.evaluate(:urgency_appropriate).value
  end

  test "urgency_appropriate passes for urgent chest pain" do
    @engine.set_facts(reason_for_referral: "Chest pain with cardiac risk", urgency: :urgent)
    assert @engine.evaluate(:urgency_appropriate).value
  end

  test "urgency_appropriate passes for emergent severe condition" do
    @engine.set_facts(reason_for_referral: "Severe chest pain suspected MI", urgency: :emergent)
    assert @engine.evaluate(:urgency_appropriate).value
  end

  test "urgency_appropriate fails for emergent chronic condition" do
    @engine.set_facts(reason_for_referral: "Chronic mild headache", urgency: :emergent)
    assert_equal false, @engine.evaluate(:urgency_appropriate).value
  end

  # === PAYOR COORDINATION ===

  test "has_payor_coordination passes for all valid coverage types" do
    Corvid::PrcEligibilityRuleset::VALID_COVERAGE_TYPES.each do |coverage|
      engine = Corvid::RulesEngine.new(Corvid::PrcEligibilityRuleset.new)
      engine.set_facts(coverage_type: coverage)
      assert engine.evaluate(:has_payor_coordination).value, "Expected #{coverage} to be valid"
    end
  end

  test "has_payor_coordination fails for invalid type" do
    @engine.set_facts(coverage_type: "Unknown")
    assert_equal false, @engine.evaluate(:has_payor_coordination).value
  end

  test "has_payor_coordination handles whitespace" do
    @engine.set_facts(coverage_type: "  IHS  ")
    assert @engine.evaluate(:has_payor_coordination).value
  end

  # === TOP-LEVEL ELIGIBILITY ===

  test "is_eligible passes when all checks pass" do
    @engine.set_facts(
      enrollment_number: "ANLC-12345", service_area: "Anchorage",
      reason_for_referral: "Chest pain cardiac evaluation",
      urgency: :urgent, coverage_type: "IHS"
    )
    result = @engine.evaluate(:is_eligible)
    assert result.value
    assert_equal 4, result.reasons.length
  end

  test "is_eligible fails when any check fails" do
    @engine.set_facts(
      enrollment_number: "INVALID", service_area: "Anchorage",
      reason_for_referral: "Chest pain", urgency: :urgent, coverage_type: "IHS"
    )
    assert_equal false, @engine.evaluate(:is_eligible).value
  end

  # === MESSAGE GENERATION ===

  test "message_for generates enrollment pass message" do
    msg = Corvid::PrcEligibilityRuleset.message_for(:is_tribally_enrolled, true, enrollment_number: "ANLC-12345")
    assert_includes msg, "Valid tribal enrollment"
    assert_includes msg, "ANLC-12345"
  end

  test "message_for generates enrollment fail message" do
    msg = Corvid::PrcEligibilityRuleset.message_for(:is_tribally_enrolled, false, {})
    assert_includes msg, "Invalid or missing"
  end

  test "message_for generates payor IHS message" do
    msg = Corvid::PrcEligibilityRuleset.message_for(:has_payor_coordination, true, coverage_type: "IHS")
    assert_includes msg, "IHS is primary payor"
  end

  test "message_for generates payor Medicare message" do
    msg = Corvid::PrcEligibilityRuleset.message_for(:has_payor_coordination, true, coverage_type: "Medicare/IHS")
    assert_includes msg, "Medicare is primary"
  end

  test "message_for generates clinical necessity pass message" do
    msg = Corvid::PrcEligibilityRuleset.message_for(:has_clinical_necessity, true, urgency: :urgent, service_requested: "Cardiology")
    assert_includes msg, "Clinical necessity documented"
    assert_includes msg, "URGENT"
  end
end
