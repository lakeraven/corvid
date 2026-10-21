# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "corvid/adapters/fhir_demo_adapter"
require_relative "../../support/adapter_contract_tests"
require_relative "../../support/fhir_adapter_contract_fixtures"

module Corvid
  module Adapters
    class FhirDemoAdapterContractHarness < FhirDemoAdapter
      private

      def fhir_create(_resource_type, _body)
        { "id" => "rf_contract_created" }
      end

      def fhir_update(_resource_type, _id, _body)
        true
      end
    end
  end
end

class Corvid::Adapters::FhirDemoAdapterContractTest < Minitest::Test
  include AdapterContractTests

  def contract_adapter
    @adapter
  end

  def contract_unsupported
    FHIR_ADAPTER_CONTRACT_UNSUPPORTED
  end

  def contract_seed!
    adapter = contract_adapter
    adapter.instance_variable_get(:@by_type).clear
    adapter.instance_variable_get(:@by_type_and_id).clear

    fixtures = FhirAdapterContractFixtures
    [
      fixtures.patient_resource("pt_contract_001", "TEST", "PATIENT 001"),
      fixtures.practitioner_resource("pr_contract_001", "TEST", "PROVIDER 001"),
      fixtures.service_request_resource("rf_contract_001", "pt_contract_001"),
      fixtures.coverage_resource("cov_contract_001", "pt_contract_001"),
      fixtures.care_team_resource("ct_contract_001", "pt_contract_001", "pr_contract_001"),
      fixtures.claim_resource("clm_contract_001", "pt_contract_001")
    ].each { |r| adapter.add_resource(r) }

    {
      patient_id: "pt_contract_001",
      unknown_patient_id: "pt_contract_unknown",
      patient_search_query: "PATIENT",
      practitioner_id: "pr_contract_001",
      unknown_practitioner_id: "pr_contract_unknown",
      practitioner_search_query: "PROVIDER",
      referral_id: "rf_contract_001",
      unknown_referral_id: "rf_contract_unknown",
      text_token: "nt_contract_unused",
      case_token: "ct_contract_001",
      obligation_id: "obl_contract_001",
      unknown_obligation_id: "obl_contract_unknown",
      payment_id: "pay_contract_001",
      claim_id: "clm_contract_001",
      payer_id: "MOCK_PAYER",
      dereference_tokens: %w[pt_contract_001]
    }
  end

  def setup
    @adapter = Corvid::Adapters::FhirDemoAdapterContractHarness.new(resources: [])
  end
end
