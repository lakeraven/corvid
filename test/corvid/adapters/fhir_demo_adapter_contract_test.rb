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

  def contract_seed!(coverage_answer_as_of: nil)
    fixtures = FhirAdapterContractFixtures
    @adapter = Corvid::Adapters::FhirDemoAdapter.new(
      resources: [
        fixtures.patient_resource("pt_contract_001", "TEST", "PATIENT 001"),
        fixtures.patient_resource_tribal_no_confidence("pt_contract_002", "TEST", "PATIENT 002"),
        fixtures.practitioner_resource("pr_contract_001", "TEST", "PROVIDER 001"),
        fixtures.service_request_resource("rf_contract_001", "pt_contract_001"),
        fixtures.coverage_resource("cov_contract_001", "pt_contract_001", last_updated: coverage_answer_as_of),
        fixtures.inactive_coverage_resource("cov_contract_002", "pt_contract_001"),
        fixtures.care_team_resource("ct_contract_001", "pt_contract_001", "pr_contract_001"),
        fixtures.claim_resource("clm_contract_001", "pt_contract_001")
      ]
    )

    {
      patient_identifier: "pt_contract_001",
      patient_identifier_tribal_no_confidence: "pt_contract_002",
      unknown_patient_identifier: "pt_contract_unknown",
      patient_search_query: "PATIENT",
      practitioner_identifier: "pr_contract_001",
      unknown_practitioner_identifier: "pr_contract_unknown",
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
      dereference_tokens: %w[pt_contract_001],
      simulate_failed_list_search: AdapterContractTests::FHIR_SIMULATE_FAILED_LIST_SEARCH
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
