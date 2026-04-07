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

  # -- ADR 0003: MockAdapter is not a security boundary ----------------------

  def test_mock_adapter_documents_it_is_not_a_security_boundary
    # MockAdapter should be flagged in source as dev/test only.
    source = File.read(File.expand_path("../../../lib/corvid/adapters/mock_adapter.rb", __dir__))
    assert_match(/not a security boundary/i, source)
  end
end
