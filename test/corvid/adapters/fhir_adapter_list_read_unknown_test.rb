# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "corvid/adapters/fhir_adapter"

# Issue #674: list/search reads must distinguish failed search (nil) from
# an answered empty bundle ([]), matching get_conditions / get_medications.
class Corvid::Adapters::FhirAdapterListReadUnknownTest < Minitest::Test
  EMPTY_SEARCHSET = {
    "resourceType" => "Bundle",
    "type" => "searchset",
    "entry" => []
  }.freeze

  def setup
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
  end

  def test_search_patients_returns_nil_when_fhir_search_returns_nil
    result = @adapter.stub(:fhir_search, nil) { @adapter.search_patients("TEST,PATIENT") }

    assert_nil result
  end

  def test_search_patients_returns_empty_array_when_fhir_search_returns_empty_searchset
    result = @adapter.stub(:fhir_search, EMPTY_SEARCHSET) { @adapter.search_patients("TEST,PATIENT") }

    assert_equal [], result
  end

  def test_search_practitioners_returns_nil_when_fhir_search_returns_nil
    result = @adapter.stub(:fhir_search, nil) { @adapter.search_practitioners("TEST,PROVIDER") }

    assert_nil result
  end

  def test_search_practitioners_returns_empty_array_when_fhir_search_returns_empty_searchset
    result = @adapter.stub(:fhir_search, EMPTY_SEARCHSET) { @adapter.search_practitioners("TEST,PROVIDER") }

    assert_equal [], result
  end

  def test_list_referrals_returns_nil_when_fhir_search_returns_nil
    result = @adapter.stub(:fhir_search, nil) { @adapter.list_referrals("pt_test_001") }

    assert_nil result
  end

  def test_list_referrals_returns_empty_array_when_fhir_search_returns_empty_searchset
    result = @adapter.stub(:fhir_search, EMPTY_SEARCHSET) { @adapter.list_referrals("pt_test_001") }

    assert_equal [], result
  end

  def test_list_claims_returns_nil_when_fhir_search_returns_nil
    result = @adapter.stub(:fhir_search, nil) { @adapter.list_claims("pt_test_001") }

    assert_nil result
  end

  def test_list_claims_returns_empty_array_when_fhir_search_returns_empty_searchset
    result = @adapter.stub(:fhir_search, EMPTY_SEARCHSET) { @adapter.list_claims("pt_test_001") }

    assert_equal [], result
  end

  def test_get_care_team_returns_nil_when_fhir_search_returns_nil
    result = @adapter.stub(:fhir_search, nil) { @adapter.get_care_team("pt_test_001") }

    assert_nil result
  end

  def test_get_care_team_returns_empty_array_when_fhir_search_returns_empty_searchset
    result = @adapter.stub(:fhir_search, EMPTY_SEARCHSET) { @adapter.get_care_team("pt_test_001") }

    assert_equal [], result
  end
end
