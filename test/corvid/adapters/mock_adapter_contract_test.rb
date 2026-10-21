# frozen_string_literal: true

require "minitest/autorun"
require "ostruct"
require "active_support/all"
require "corvid/adapters/mock_adapter"
require_relative "../../support/adapter_contract_tests"

class Corvid::Adapters::MockAdapterContractTest < Minitest::Test
  include AdapterContractTests

  def contract_adapter
    @adapter
  end

  def contract_unsupported
    {}
  end

  def contract_seed!
    adapter = contract_adapter
    adapter.reset!

    adapter.add_patient(
      "pt_contract_001",
      display_name: "TEST,PATIENT 001",
      dob: Date.new(1980, 1, 1),
      sex: "F",
      ssn_last4: "0001",
      birthplace: "TEST CITY, WA"
    )
    adapter.add_practitioner(
      "pr_contract_001",
      display_name: "TEST,PROVIDER 001",
      npi: "0000000001",
      specialty: "TEST"
    )
    stored_text = "TEST CONTRACT NOTE"
    text_token = adapter.store_text(case_token: "ct_contract_001", kind: :note, text: stored_text)
    adapter.add_referral(
      "rf_contract_001",
      patient_identifier: "pt_contract_001",
      status: "pending",
      reason_token: text_token,
      estimated_cost: 500.0,
      medical_priority_level: 3,
      authorization_number: nil,
      emergent: false,
      urgent: false,
      chs_approval_status: "P",
      service_requested: "TEST,CONTRACT SERVICE",
      requesting_provider_identifier: "pr_contract_001"
    )
    adapter.add_enrollment(
      "pt_contract_001",
      enrolled: true,
      membership_number: "TEST-CONTRACT-001",
      tribe_name: "TEST TRIBE",
      tribe_code: "TST",
      member_status: "enrolled",
      blood_quantum: { fraction: "1/4" },
      confidence: :verified
    )
    adapter.add_patient(
      "pt_contract_002",
      display_name: "TEST,PATIENT 002",
      dob: Date.new(1990, 5, 5),
      sex: "M",
      ssn_last4: "0002",
      birthplace: "TEST CITY, WA"
    )
    adapter.add_enrollment(
      "pt_contract_002",
      enrolled: true,
      membership_number: "TEST-CONTRACT-002",
      tribe_name: "TEST TRIBE",
      tribe_code: "TST",
      member_status: "enrolled"
    )
    adapter.add_coverage(
      "pt_contract_001",
      resource_type: "medicaid",
      coverage_type: "medicaid",
      payer_identifier: "MOCK_PAYER",
      payer_name: "MOCK MEDICAID PAYER",
      plan_name: "Mock Medicaid",
      eligible: true
    )
    adapter.add_residency(
      "pt_contract_001",
      on_reservation: true,
      address: "123 TEST ST",
      service_area: "test_area"
    )
    adapter.add_care_team(
      "pt_contract_001",
      [
        {
          practitioner_identifier: "pr_contract_001",
          role: "practitioner",
          name: "TEST CARE TEAM",
          status: "active"
        }
      ]
    )
    obligation = adapter.create_obligation("rf_contract_001", 100.0)
    payment = adapter.process_payment(
      amount_cents: 100,
      patient_identifier: "pt_contract_001",
      description: "TEST CONTRACT PAYMENT"
    )
    adapter.add_claim(
      "clm_contract_001",
      status: "accepted",
      paid_amount: 50.0,
      adjustment_amount: 0.0,
      paid_date: Date.new(2026, 1, 1)
    )

    {
      patient_identifier: "pt_contract_001",
      patient_identifier_tribal_no_confidence: "pt_contract_002",
      unknown_patient_identifier: "pt_contract_unknown",
      patient_search_query: "PATIENT 001",
      practitioner_identifier: "pr_contract_001",
      unknown_practitioner_identifier: "pr_contract_unknown",
      practitioner_search_query: "PROVIDER 001",
      referral_identifier: "rf_contract_001",
      unknown_referral_identifier: "rf_contract_unknown",
      text_token: text_token,
      stored_text: stored_text,
      case_token: "ct_contract_001",
      obligation_identifier: obligation.id,
      unknown_obligation_identifier: "obl_contract_unknown",
      obligation_seeded: true,
      payment_identifier: payment[:payment_identifier],
      unknown_payment_identifier: "pay_contract_unknown",
      claim_identifier: "clm_contract_001",
      payer_identifier: "MOCK_PAYER",
      unknown_payer_identifier: "PAYER_CONTRACT_UNKNOWN",
      coverage_resource_type: "medicaid",
      other_resource_type: "medicare_a",
      dereference_tokens: %w[pt_contract_001 rf_contract_001],
      care_team_seeded: true,
      claims_listable: false
    }
  end

  def setup
    @adapter = Corvid::Adapters::MockAdapter.new
    @adapter.reset!
  end
end
