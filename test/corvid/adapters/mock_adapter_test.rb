# frozen_string_literal: true

require "minitest/autorun"
require "corvid/adapters/mock_adapter"

class Corvid::Adapters::MockAdapterTest < Minitest::Test
  def setup
    @adapter = Corvid::Adapters::MockAdapter.new
  end

  # -- Vault: store_text + fetch_text round-trip ------------------------------

  def test_store_text_returns_prefixed_token
    token = @adapter.store_text(case_token: "ct_test", kind: :note, text: "TEST NOTE 001")
    assert_match(/\Ant_/, token)
  end

  def test_store_text_returns_unique_tokens
    a = @adapter.store_text(case_token: "ct_test", kind: :note, text: "A")
    b = @adapter.store_text(case_token: "ct_test", kind: :note, text: "B")
    refute_equal a, b
  end

  def test_fetch_text_round_trips
    token = @adapter.store_text(case_token: "ct_test", kind: :note, text: "TEST NOTE 001")
    assert_equal "TEST NOTE 001", @adapter.fetch_text(token)
  end

  def test_fetch_text_returns_nil_for_unknown_token
    assert_nil @adapter.fetch_text("nt_does_not_exist")
  end

  def test_store_text_uses_kind_specific_prefix
    note    = @adapter.store_text(case_token: "ct_x", kind: :note, text: "n")
    reason  = @adapter.store_text(case_token: "ct_x", kind: :reason, text: "r")
    rationale = @adapter.store_text(case_token: "ct_x", kind: :rationale, text: "ra")
    policy  = @adapter.store_text(case_token: "ct_x", kind: :policy, text: "p")

    assert_match(/\Ant_/, note)
    assert_match(/\Ars_/, reason)
    assert_match(/\Arn_/, rationale)
    assert_match(/\Apo_/, policy)
  end

  # -- Patient lookup returns PatientReference (no PHI by default) ------------

  def test_find_patient_returns_patient_reference
    @adapter.add_patient("pt_001", display_name: "TEST,PATIENT", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "0000")
    result = @adapter.find_patient("pt_001")
    assert_instance_of Corvid::PatientReference, result
    assert_equal "pt_001", result.identifier
    assert_equal "TEST,PATIENT", result.display_name
  end

  def test_find_patient_returns_nil_for_unknown_token
    assert_nil @adapter.find_patient("pt_unknown")
  end

  # -- Practitioner lookup ----------------------------------------------------

  def test_find_practitioner_returns_practitioner_reference
    @adapter.add_practitioner("pr_001", display_name: "TEST,PROVIDER", npi: "0000000000", specialty: "TEST")
    result = @adapter.find_practitioner("pr_001")
    assert_instance_of Corvid::PractitionerReference, result
    assert_equal "pr_001", result.identifier
  end

  # -- Referral lookup --------------------------------------------------------

  def test_find_referral_returns_referral_reference
    @adapter.add_referral("rf_001", patient_identifier: "pt_001", status: "pending",
                          estimated_cost: 5000, medical_priority_level: 3,
                          authorization_number: "AUTH-001", emergent: false, urgent: false,
                          chs_approval_status: "P", service_requested: "TEST")
    result = @adapter.find_referral("rf_001")
    assert_instance_of Corvid::ReferralReference, result
    assert_equal "rf_001", result.identifier
    assert_equal "pt_001", result.patient_identifier
    assert_equal "AUTH-001", result.authorization_number
  end

  # -- Care team --------------------------------------------------------------

  def test_get_care_team_returns_array_of_references
    @adapter.add_care_team("pt_001", [
      { practitioner_identifier: "pr_001", role: "primary_care", name: "Primary Team", status: "active" }
    ])
    result = @adapter.get_care_team("pt_001")
    assert_equal 1, result.size
    assert_instance_of Corvid::CareTeamMemberReference, result.first
    assert_equal "pr_001", result.first.practitioner_identifier
  end

  def test_get_care_team_returns_empty_for_unknown_patient
    assert_equal [], @adapter.get_care_team("pt_unknown")
  end

  # -- Eligibility ------------------------------------------------------------

  def test_verify_eligibility_returns_eligible_for_seeded_resource_type
    result = @adapter.verify_eligibility("pt_001", "medicaid")
    assert result[:eligible]
    assert result[:payer_name]
  end

  # -- Budget -----------------------------------------------------------------

  def test_get_budget_summary_returns_total_obligated_remaining
    summary = @adapter.get_budget_summary
    assert summary[:total]
    assert summary[:obligated]
    assert summary[:remaining]
  end

  # -- Reset for tests --------------------------------------------------------

  def test_reset_clears_all_state
    @adapter.add_patient("pt_001", display_name: "TEST", dob: nil, sex: nil, ssn_last4: nil)
    @adapter.store_text(case_token: "ct_x", kind: :note, text: "before reset")
    @adapter.reset!
    assert_nil @adapter.find_patient("pt_001")
  end

  # -- verify_tribal_enrollment contract: tribe_code + confidence ------------

  def test_verify_tribal_enrollment_returns_tribe_code_when_added_via_add_enrollment
    @adapter.add_enrollment("pt_e1", enrolled: true, tribe_name: "Demo Tribe", tribe_code: "DEMO", member_status: "enrolled")
    result = @adapter.verify_tribal_enrollment("pt_e1")
    assert_equal "DEMO", result[:tribe_code]
    assert_equal "Demo Tribe", result[:tribe_name]
    assert result[:enrolled]
  end

  def test_verify_tribal_enrollment_defaults_confidence_to_verified
    @adapter.add_enrollment("pt_e2", enrolled: true, tribe_name: "T", tribe_code: "T")
    result = @adapter.verify_tribal_enrollment("pt_e2")
    assert_equal :verified, result[:confidence]
  end

  def test_verify_tribal_enrollment_propagates_explicit_confidence_stale
    @adapter.add_enrollment("pt_e3", enrolled: true, tribe_name: "T", tribe_code: "T", confidence: :stale)
    result = @adapter.verify_tribal_enrollment("pt_e3")
    assert_equal :stale, result[:confidence]
  end

  def test_verify_tribal_enrollment_unknown_patient_returns_not_enrolled_with_verified_confidence
    result = @adapter.verify_tribal_enrollment("pt_unknown")
    refute result[:enrolled]
    assert_nil result[:tribe_code]
    assert_equal :verified, result[:confidence]
  end

  # -- ADR 0003: MockAdapter is not a security boundary ----------------------

  def test_mock_adapter_documents_it_is_not_a_security_boundary
    # MockAdapter should be flagged in source as dev/test only.
    source = File.read(File.expand_path("../../../lib/corvid/adapters/mock_adapter.rb", __dir__))
    assert_match(/not a security boundary/i, source)
  end

  # -- Conditions / medications (issue #611) ----------------------------------

  def test_add_condition_and_get_conditions_round_trip
    ref = Corvid::ConditionReference.new(
      code: "C001", code_system: "http://example.test/codes", display: "TEST CONDITION 001",
      clinical_status: "active", category: "problem-list-item", onset_date: Date.new(2020, 3, 15)
    )
    @adapter.add_condition("pt_001", ref)
    result = @adapter.get_conditions("pt_001")
    assert_equal 1, result.size
    assert_equal ref, result.first
  end

  def test_get_conditions_returns_empty_when_none_seeded
    assert_respond_to @adapter, :add_condition
    assert_equal [], @adapter.get_conditions("pt_001")
  end

  def test_reset_clears_conditions
    ref = Corvid::ConditionReference.new(
      code: "C001", code_system: "http://example.test/codes", display: "TEST CONDITION 001",
      clinical_status: "resolved", category: "encounter-diagnosis", onset_date: nil
    )
    @adapter.add_condition("pt_001", ref)
    @adapter.reset!
    assert_equal [], @adapter.get_conditions("pt_001")
  end

  def test_add_medication_and_get_medications_round_trip
    ref = Corvid::MedicationReference.new(
      code: "M001", code_system: "http://example.test/rxnorm", display: "TEST MEDICATION 001",
      status: "active", authored_on: Date.new(2024, 6, 1), dosage_text: "TEST DOSAGE 001"
    )
    @adapter.add_medication("pt_001", ref)
    result = @adapter.get_medications("pt_001")
    assert_equal 1, result.size
    assert_equal ref, result.first
  end

  def test_get_medications_returns_empty_when_none_seeded
    assert_respond_to @adapter, :add_medication
    assert_equal [], @adapter.get_medications("pt_001")
  end

  def test_reset_clears_medications
    ref = Corvid::MedicationReference.new(
      code: "M001", code_system: "http://example.test/rxnorm", display: "TEST MEDICATION 001",
      status: "stopped", authored_on: nil, dosage_text: nil
    )
    @adapter.add_medication("pt_001", ref)
    @adapter.reset!
    assert_equal [], @adapter.get_medications("pt_001")
  end

  def test_add_condition_raises_unless_given_condition_reference
    error = assert_raises(ArgumentError) { @adapter.add_condition("pt_001", { code: "C001" }) }
    assert_match(/ConditionReference/i, error.message)
  end

  def test_add_medication_raises_unless_given_medication_reference
    error = assert_raises(ArgumentError) { @adapter.add_medication("pt_001", { code: "M001" }) }
    assert_match(/MedicationReference/i, error.message)
  end

  def test_get_conditions_returns_copy_not_internal_storage
    ref = Corvid::ConditionReference.new(
      code: "C001", code_system: "http://example.test/codes", display: "TEST CONDITION 001",
      clinical_status: "active", category: "problem-list-item", onset_date: nil
    )
    @adapter.add_condition("pt_001", ref)
    returned = @adapter.get_conditions("pt_001")
    returned.clear
    assert_equal 1, @adapter.get_conditions("pt_001").size
  end

  def test_get_medications_returns_copy_not_internal_storage
    ref = Corvid::MedicationReference.new(
      code: "M001", code_system: "http://example.test/rxnorm", display: "TEST MEDICATION 001",
      status: "active", authored_on: nil, dosage_text: nil
    )
    @adapter.add_medication("pt_001", ref)
    returned = @adapter.get_medications("pt_001")
    returned.clear
    assert_equal 1, @adapter.get_medications("pt_001").size
  end
end
