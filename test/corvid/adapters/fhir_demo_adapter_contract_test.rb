# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "corvid/adapters/fhir_demo_adapter"
require_relative "../../support/adapter_contract_tests"
require_relative "../../support/fhir_adapter_contract_fixtures"

# Runs the contract against the shipped FhirDemoAdapter, the adapter the
# FHIR overlay demo installs as Corvid.adapter. No transport method is
# stubbed or replaced: reads, searches and writes all go through the
# adapter's own in-memory store.
class Corvid::Adapters::FhirDemoAdapterContractTest < Minitest::Test
  include AdapterContractTests

  def contract_adapter
    @adapter
  end

  def contract_unsupported
    FHIR_ADAPTER_CONTRACT_UNSUPPORTED
  end

  def contract_fail_closed_stubs
    FHIR_ADAPTER_CONTRACT_FAIL_CLOSED_STUBS
  end

  def contract_seed!
    fixtures = FhirAdapterContractFixtures
    @adapter = Corvid::Adapters::FhirDemoAdapter.new(
      resources: [
        fixtures.patient_resource("pt-contract-001", "TEST", "PATIENT 001"),
        fixtures.patient_resource_tribal_no_confidence("pt-contract-002", "TEST", "PATIENT 002"),
        fixtures.practitioner_resource("pr-contract-001", "TEST", "PROVIDER 001"),
        fixtures.service_request_resource("rf_contract_001", "pt-contract-001"),
        fixtures.coverage_resource("cov_contract_001", "pt-contract-001"),
        fixtures.inactive_coverage_resource("cov_contract_002", "pt-contract-001"),
        fixtures.care_team_resource("ct_contract_001", "pt-contract-001", "pr-contract-001"),
        fixtures.claim_resource("clm_contract_001", "pt-contract-001")
      ]
    )

    {
      patient_identifier: "pt-contract-001",
      patient_identifier_tribal_no_confidence: "pt-contract-002",
      unknown_patient_identifier: "pt-contract-unknown",
      patient_search_query: "PATIENT",
      practitioner_identifier: "pr-contract-001",
      unknown_practitioner_identifier: "pr-contract-unknown",
      practitioner_search_query: "PROVIDER",
      referral_identifier: "rf_contract_001",
      unknown_referral_identifier: "rf_contract_unknown",
      text_token: "nt_contract_unused",
      stored_text: "TEST CONTRACT NOTE",
      case_token: "ct_contract_001",
      obligation_identifier: "obl_contract_001",
      unknown_obligation_identifier: "obl_contract_unknown",
      payment_identifier: "pay_contract_001",
      unknown_payment_identifier: "pay_contract_unknown",
      claim_identifier: "clm_contract_001",
      payer_identifier: "MOCK_PAYER",
      unknown_payer_identifier: "PAYER_CONTRACT_UNKNOWN",
      payer_search_query: "TEST PAYER",
      coverage_resource_type: "medicaid",
      other_resource_type: "medicare_a",
      inactive_coverage_resource_type: "va_benefits",
      dereference_tokens: %w[pt-contract-001]
    }
  end

  def test_contract_runs_against_the_shipped_adapter_class
    contract_seed!
    assert_equal Corvid::Adapters::FhirDemoAdapter, contract_adapter.class,
                 "the contract must exercise FhirDemoAdapter itself, not a test subclass"
  end

  def setup
    @adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [])
  end
end
