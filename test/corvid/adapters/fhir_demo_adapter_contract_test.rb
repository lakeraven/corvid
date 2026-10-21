# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "corvid/adapters/fhir_demo_adapter"
require_relative "../../support/adapter_contract_tests"
require_relative "../../support/fhir_adapter_contract_fixtures"
require_relative "../../support/fhir_contract_harness_search"

module Corvid
  module Adapters
    class FhirDemoAdapterContractHarness < FhirDemoAdapter
      include FhirContractHarnessSearch

      attr_accessor :contract_fhir_update_returns

      def initialize(resources: [])
        super(resources: resources)
        @contract_fhir_update_returns = true
      end

      private

      def fhir_search(resource_type, params = {})
        params = params.transform_keys(&:to_s)
        matches = @by_type[resource_type].select { |r| contract_harness_search_match?(resource_type, r, params) }
        {
          "resourceType" => "Bundle",
          "type" => "searchset",
          "total" => matches.size,
          "entry" => matches.map { |r| { "resource" => r } }
        }
      end

      def fhir_create(_resource_type, _body)
        { "id" => "rf_contract_created" }
      end

      def fhir_update(_resource_type, _id, _body)
        contract_fhir_update_returns
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
    adapter.contract_fhir_update_returns = true

    fixtures = FhirAdapterContractFixtures
    [
      fixtures.patient_resource("pt_contract_001", "TEST", "PATIENT 001"),
      fixtures.patient_resource_tribal_no_confidence("pt_contract_002", "TEST", "PATIENT 002"),
      fixtures.practitioner_resource("pr_contract_001", "TEST", "PROVIDER 001"),
      fixtures.service_request_resource("rf_contract_001", "pt_contract_001"),
      fixtures.coverage_resource("cov_contract_001", "pt_contract_001"),
      fixtures.care_team_resource("ct_contract_001", "pt_contract_001", "pr_contract_001"),
      fixtures.claim_resource("clm_contract_001", "pt_contract_001")
    ].each { |r| adapter.add_resource(r) }

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
      obligation_seeded: false,
      payment_identifier: "pay_contract_001",
      unknown_payment_identifier: "pay_contract_unknown",
      claim_identifier: "clm_contract_001",
      payer_identifier: "MOCK_PAYER",
      dereference_tokens: %w[pt_contract_001],
      care_team_seeded: true,
      claims_listable: true
    }
  end

  def test_contract_update_referral_fhir_update_returns_false
    validate_contract_unsupported!
    seed = contract_seed!
    validate_required_seed_keys!(seed)
    adapter = contract_adapter
    adapter.contract_fhir_update_returns = false
    refute adapter.update_referral(seed[:referral_identifier], { status: "active" }),
           "update_referral must return false when fhir_update returns false"
  end

  def setup
    @adapter = Corvid::Adapters::FhirDemoAdapterContractHarness.new(resources: [])
  end
end
