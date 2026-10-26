# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "corvid/adapters/fhir_demo_adapter"

class Corvid::Adapters::FhirDemoAdapterListReadUnknownTest < Minitest::Test
  EMPTY_SEARCHSET = {
    "resourceType" => "Bundle",
    "type" => "searchset",
    "entry" => []
  }.freeze

  def setup
    @adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [])
  end

  def test_list_claims_returns_nil_when_fhir_search_returns_nil
    result = @adapter.stub(:fhir_search, nil) { @adapter.list_claims("pt_test_001") }

    assert_nil result
  end

  def test_list_claims_returns_empty_array_when_fhir_search_returns_empty_searchset
    result = @adapter.stub(:fhir_search, EMPTY_SEARCHSET) { @adapter.list_claims("pt_test_001") }

    assert_equal [], result
  end
end
