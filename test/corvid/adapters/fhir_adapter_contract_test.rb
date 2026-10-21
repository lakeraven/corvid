# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "corvid/adapters/fhir_adapter"
require_relative "../../support/adapter_contract_tests"
require_relative "../../support/fhir_adapter_contract_fixtures"

module Corvid
  module Adapters
    # Test-only transport: exercises FhirAdapter parsing without network.
    class FhirAdapterContractHarness < FhirAdapter
      def initialize
        super(base_url: "https://fhir.contract.test/r4")
        @by_type_and_id = Hash.new { |h, k| h[k] = {} }
        @by_type = Hash.new { |h, k| h[k] = [] }
        @create_responses = {}
      end

      def add_resource(resource)
        type = resource["resourceType"]
        @by_type[type] << resource
        @by_type_and_id[type][resource["id"]] = resource if resource["id"]
        resource
      end

      def stub_create(resource_type, response_body)
        @create_responses[resource_type] = response_body
      end

      private

      def fhir_read(resource_type, id)
        @by_type_and_id[resource_type][id.to_s]
      end

      def fhir_search(resource_type, params = {})
        params = params.transform_keys(&:to_s)
        matches = @by_type[resource_type].select { |r| search_match?(resource_type, r, params) }
        {
          "resourceType" => "Bundle",
          "type" => "searchset",
          "total" => matches.size,
          "entry" => matches.map { |r| { "resource" => r } }
        }
      end

      def fhir_create(resource_type, _body)
        @create_responses[resource_type]
      end

      def fhir_update(_resource_type, _id, _body)
        true
      end

      def search_match?(resource_type, resource, params)
        params.all? do |key, value|
          case key
          when "patient", "beneficiary", "subject"
            reference_matches?(resource, value)
          when "name"
            name_matches?(resource, value)
          else
            true
          end
        end
      end

      def reference_matches?(resource, value)
        wanted = value.to_s.sub(%r{\APatient/}, "")
        candidates = [
          resource.dig("patient", "reference"),
          resource.dig("beneficiary", "reference"),
          resource.dig("subject", "reference")
        ].compact.map { |ref| ref.sub(%r{\APatient/}, "") }
        candidates.include?(wanted)
      end

      def name_matches?(resource, value)
        needle = value.to_s.downcase
        Array(resource["name"]).any? do |n|
          [ n["family"], *Array(n["given"]) ].compact.any? { |part| part.downcase.include?(needle) }
        end
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

  def contract_seed!
    adapter = contract_adapter
    adapter.instance_variable_set(:@by_type_and_id, Hash.new { |h, k| h[k] = {} })
    adapter.instance_variable_set(:@by_type, Hash.new { |h, k| h[k] = [] })

    adapter.add_resource(FhirAdapterContractFixtures.patient_resource("pt_contract_001", "TEST", "PATIENT 001"))
    adapter.add_resource(FhirAdapterContractFixtures.practitioner_resource("pr_contract_001", "TEST", "PROVIDER 001"))
    adapter.add_resource(FhirAdapterContractFixtures.service_request_resource("rf_contract_001", "pt_contract_001"))
    adapter.add_resource(FhirAdapterContractFixtures.coverage_resource("cov_contract_001", "pt_contract_001"))
    adapter.add_resource(
      FhirAdapterContractFixtures.care_team_resource("ct_contract_001", "pt_contract_001", "pr_contract_001")
    )
    adapter.add_resource(FhirAdapterContractFixtures.claim_resource("clm_contract_001", "pt_contract_001"))
    adapter.stub_create("ServiceRequest", { "id" => "rf_contract_created" })

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
    @adapter = Corvid::Adapters::FhirAdapterContractHarness.new
  end
end
