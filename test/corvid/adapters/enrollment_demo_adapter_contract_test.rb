# frozen_string_literal: true

require "minitest/autorun"
require "ostruct"
require "active_support/all"
require "corvid/adapters/enrollment_demo_adapter"
require_relative "../../support/adapter_contract_tests"

class Corvid::Adapters::EnrollmentDemoAdapterContractTest < Minitest::Test
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
    adapter.send(:seed!)

    stored_text = "TEST CONTRACT NOTE"
    text_token = adapter.store_text(case_token: "ct_contract_001", kind: :note, text: stored_text)
    adapter.add_referral(
      "rf_contract_001",
      patient_identifier: "pt_demo_enrolled",
      status: "pending",
      reason_token: text_token,
      estimated_cost: 500.0,
      medical_priority_level: 3,
      authorization_number: nil,
      emergent: false,
      urgent: false,
      chs_approval_status: "P",
      service_requested: "TEST,CONTRACT SERVICE",
      requesting_provider_identifier: "pr_demo_001"
    )
    adapter.add_care_team(
      "pt_demo_enrolled",
      [
        {
          practitioner_identifier: "pr_demo_001",
          role: "practitioner",
          name: "DEMO CARE TEAM",
          status: "active"
        }
      ]
    )
    obligation = adapter.create_obligation("rf_contract_001", 100.0)
    payment = adapter.process_payment(
      amount_cents: 100,
      patient_identifier: "pt_demo_enrolled",
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
      patient_identifier: "pt_demo_enrolled",
      unknown_patient_identifier: "pt_contract_unknown",
      patient_search_query: "ENROLLED",
      practitioner_identifier: "pr_demo_001",
      unknown_practitioner_identifier: "pr_contract_unknown",
      practitioner_search_query: "PRC MANAGER",
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
      dereference_tokens: %w[pt_demo_enrolled rf_contract_001],
      care_team_seeded: true,
      claims_listable: false
    }
  end

  def setup
    @adapter = Corvid::Adapters::EnrollmentDemoAdapter.new
    @adapter.reset!
    @adapter.send(:seed!)
  end
end
