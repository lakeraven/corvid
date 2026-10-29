# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "corvid/adapters/fhir_adapter"
require_relative "../../support/adapter_contract_tests"
require_relative "../../support/fhir_adapter_contract_fixtures"
require_relative "../../support/fhir_contract_harness_search"

module Corvid
  module Adapters
    # Test-only transport: exercises FhirAdapter parsing without network.
    class FhirAdapterContractHarness < FhirAdapter
      include FhirContractHarnessSearch

      attr_accessor :contract_fhir_update_returns

      def initialize
        super(base_url: "https://fhir.contract.test/r4")
        @by_type_and_id = Hash.new { |h, k| h[k] = {} }
        @by_type = Hash.new { |h, k| h[k] = [] }
        @contract_fhir_update_returns = true
      end

      def add_resource(resource)
        type = resource["resourceType"]
        @by_type[type] << resource
        @by_type_and_id[type][resource["id"]] = resource if resource["id"]
        resource
      end

      private

      # A copy, as a real server returns: the store changes only through
      # fhir_create and fhir_update.
      def fhir_read(resource_type, id)
        resource = @by_type_and_id[resource_type][id.to_s]
        resource && JSON.parse(JSON.generate(resource))
      end

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

      def fhir_create(resource_type, body)
        resource = JSON.parse(JSON.generate(body)).merge("id" => "#{resource_type.downcase}-contract-#{@by_type[resource_type].size + 1}")
        add_resource(resource)
      end

      def fhir_update(resource_type, id, body)
        return false unless contract_fhir_update_returns
        return false unless @by_type_and_id[resource_type].key?(id.to_s)

        resource = JSON.parse(JSON.generate(body)).merge("id" => id.to_s)
        @by_type[resource_type].reject! { |r| r["id"] == id.to_s }
        add_resource(resource)
        true
      end
    end
  end
end

class Corvid::Adapters::FhirAdapterContractTest < Minitest::Test
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
    adapter = contract_adapter
    adapter.instance_variable_set(:@by_type_and_id, Hash.new { |h, k| h[k] = {} })
    adapter.instance_variable_set(:@by_type, Hash.new { |h, k| h[k] = [] })
    adapter.contract_fhir_update_returns = true

    fixtures = FhirAdapterContractFixtures
    adapter.add_resource(fixtures.patient_resource("pt-contract-001", "TEST", "PATIENT 001"))
    adapter.add_resource(
      fixtures.patient_resource_tribal_no_confidence("pt-contract-002", "TEST", "PATIENT 002")
    )
    adapter.add_resource(fixtures.practitioner_resource("pr-contract-001", "TEST", "PROVIDER 001"))
    adapter.add_resource(fixtures.service_request_resource("rf_contract_001", "pt-contract-001"))
    adapter.add_resource(fixtures.coverage_resource("cov_contract_001", "pt-contract-001", last_updated: coverage_answer_as_of))
    adapter.add_resource(fixtures.inactive_coverage_resource("cov_contract_002", "pt-contract-001"))
    adapter.add_resource(
      fixtures.care_team_resource("ct_contract_001", "pt-contract-001", "pr-contract-001")
    )
    adapter.add_resource(fixtures.claim_resource("clm_contract_001", "pt-contract-001"))

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
      dereference_tokens: %w[pt-contract-001],
      simulate_failed_list_search: AdapterContractTests::FHIR_SIMULATE_FAILED_LIST_SEARCH
    }
  end

  def test_contract_update_referral_fhir_update_returns_false
    validate_contract_hooks!
    seed = contract_seed!
    validate_required_seed_keys!(seed)
    adapter = contract_adapter
    adapter.contract_fhir_update_returns = false
    refute adapter.update_referral(seed[:referral_identifier], { status: "on-hold" }),
           "update_referral must return false when fhir_update returns false"
    assert_equal "active", adapter.find_referral(seed[:referral_identifier]).status,
                 "a failed fhir_update must leave the stored referral unchanged"
  end

  def setup
    @adapter = Corvid::Adapters::FhirAdapterContractHarness.new
  end
end
