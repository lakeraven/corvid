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

    text_token = adapter.store_text(case_token: "ct_contract_001", kind: :note, text: "TEST CONTRACT NOTE")
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
      patient_id: "pt_demo_enrolled",
      unknown_patient_id: "pt_contract_unknown",
      patient_search_query: "ENROLLED",
      practitioner_id: "pr_demo_001",
      unknown_practitioner_id: "pr_contract_unknown",
      practitioner_search_query: "PRC MANAGER",
      referral_id: "rf_contract_001",
      unknown_referral_id: "rf_contract_unknown",
      text_token: text_token,
      case_token: "ct_contract_001",
      obligation_id: obligation.id,
      unknown_obligation_id: "obl_contract_unknown",
      payment_id: payment[:payment_identifier],
      claim_id: "clm_contract_001",
      payer_id: "MOCK_PAYER",
      dereference_tokens: %w[pt_demo_enrolled rf_contract_001]
    }
  end

  def setup
    @adapter = Corvid::Adapters::EnrollmentDemoAdapter.new
    @adapter.reset!
    @adapter.send(:seed!)
  end
end
