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
    text_token = adapter.store_text(case_token: "ct_contract_001", kind: :note, text: "TEST CONTRACT NOTE")
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
      confidence: :verified
    )
    adapter.add_residency(
      "pt_contract_001",
      on_reservation: true,
      address: "123 TEST ST",
      service_area: "test_area"
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
      patient_id: "pt_contract_001",
      unknown_patient_id: "pt_contract_unknown",
      patient_search_query: "PATIENT 001",
      practitioner_id: "pr_contract_001",
      unknown_practitioner_id: "pr_contract_unknown",
      practitioner_search_query: "PROVIDER 001",
      referral_id: "rf_contract_001",
      unknown_referral_id: "rf_contract_unknown",
      text_token: text_token,
      case_token: "ct_contract_001",
      obligation_id: obligation.id,
      unknown_obligation_id: "obl_contract_unknown",
      payment_id: payment[:payment_identifier],
      claim_id: "clm_contract_001",
      payer_id: "MOCK_PAYER",
      dereference_tokens: %w[pt_contract_001 rf_contract_001]
    }
  end

  def setup
    @adapter = Corvid::Adapters::MockAdapter.new
    @adapter.reset!
  end
end
