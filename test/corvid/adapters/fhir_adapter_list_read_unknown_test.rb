# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "json"
require "corvid/adapters/fhir_adapter"

# Issue #674: list/search reads must distinguish failed search (nil) from
# an answered empty bundle ([]), matching get_conditions / get_medications.
class Corvid::Adapters::FhirAdapterListReadUnknownTest < Minitest::Test
  EMPTY_SEARCHSET = {
    "resourceType" => "Bundle",
    "type" => "searchset",
    "entry" => []
  }.freeze

  OUTCOME_ONLY_SEARCHSET = {
    "resourceType" => "Bundle",
    "type" => "searchset",
    "entry" => [
      {
        "resource" => {
          "resourceType" => "OperationOutcome",
          "issue" => [ { "severity" => "error", "code" => "too-costly" } ]
        },
        "search" => { "mode" => "outcome" }
      }
    ]
  }.freeze

  PATIENT_SCOPED_READS = {
    list_referrals: "pt_test_001",
    list_claims: "pt_test_001",
    get_care_team: "pt_test_001"
  }.freeze

  NAME_SEARCH_READS = {
    search_patients: "TEST,PATIENT",
    search_practitioners: "TEST,PROVIDER"
  }.freeze

  LIST_READS = PATIENT_SCOPED_READS.merge(NAME_SEARCH_READS).freeze

  TRANSPORT_ERRORS = [
    Errno::ECONNREFUSED,
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError
  ].freeze

  def setup
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
  end

  # --- fhir_search nil / empty searchset (baseline) -----------------------

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

  # --- real fhir_search via http_get ----------------------------------------

  UNTYPED_EMPTY_BUNDLE = {
    "resourceType" => "Bundle",
    "entry" => []
  }.freeze

  NON_SEARCHSET_BUNDLE_TYPES = %w[collection transaction-response].freeze

  LIST_READS.each_key do |method|
    define_method("test_#{method}_returns_nil_for_untyped_empty_bundle_via_http") do
      arg = LIST_READS.fetch(method)
      result = with_http_bundle(UNTYPED_EMPTY_BUNDLE) { @adapter.public_send(method, arg) }

      assert_nil result, "#{method}: Bundle without type is not an answered search"
    end

    define_method("test_#{method}_returns_nil_for_untyped_bundle_with_match_entry_via_http") do
      entry = untyped_match_bundle_entry(method)
      bundle = { "resourceType" => "Bundle", "entry" => [ entry ] }
      arg = LIST_READS.fetch(method)
      result = with_http_bundle(bundle) { @adapter.public_send(method, arg) }

      assert_nil result, "#{method}: untyped Bundle with matches must not be treated as searchset"
    end
  end

  NON_SEARCHSET_BUNDLE_TYPES.each do |bundle_type|
    LIST_READS.each_key do |method|
      define_method("test_#{method}_returns_nil_for_#{bundle_type.tr('-', '_')}_bundle_via_http") do
        bundle = { "resourceType" => "Bundle", "type" => bundle_type, "entry" => [] }
        arg = LIST_READS.fetch(method)
        result = with_http_bundle(bundle) { @adapter.public_send(method, arg) }

        assert_nil result, "#{method}: Bundle.type #{bundle_type} is not an answered search"
      end
    end
  end

  LIST_READS.each_key do |method|
    define_method("test_#{method}_returns_nil_for_outcome_only_searchset_via_http") do
      arg = LIST_READS.fetch(method)
      result = with_http_bundle(OUTCOME_ONLY_SEARCHSET) { @adapter.public_send(method, arg) }

      assert_nil result, "#{method} must treat outcome-only searchset as unknown"
    end

    define_method("test_#{method}_returns_empty_array_for_answered_empty_searchset_via_http") do
      arg = LIST_READS.fetch(method)
      result = with_http_bundle(EMPTY_SEARCHSET) { @adapter.public_send(method, arg) }

      assert_equal [], result
    end
  end

  PATIENT_SCOPED_READS.each_key do |method|
    define_method("test_#{method}_returns_nil_for_null_bundle_entry_via_http") do
      bundle = { "resourceType" => "Bundle", "type" => "searchset", "entry" => [ nil ] }
      arg = PATIENT_SCOPED_READS.fetch(method)
      result = with_http_bundle(bundle) { @adapter.public_send(method, arg) }

      assert_nil result, "#{method} must not raise on null entry"
    end

    define_method("test_#{method}_returns_nil_for_string_entry_resource_via_http") do
      bundle = { "resourceType" => "Bundle", "type" => "searchset", "entry" => [ { "resource" => "x" } ] }
      arg = PATIENT_SCOPED_READS.fetch(method)
      result = with_http_bundle(bundle) { @adapter.public_send(method, arg) }

      assert_nil result, "#{method} must not raise on string resource"
    end
  end

  def test_list_claims_returns_nil_when_claim_item_is_not_a_hash_via_http
    bundle = {
      "resourceType" => "Bundle",
      "type" => "searchset",
      "entry" => [
        claim_bundle_entry(item: [ "junk" ])
      ]
    }
    result = with_http_bundle(bundle) { @adapter.list_claims("pt_test_001") }

    assert_nil result
  end

  def test_list_referrals_omits_include_mode_patient_entry_via_http
    bundle = {
      "resourceType" => "Bundle",
      "type" => "searchset",
      "entry" => [
        patient_bundle_entry(mode: "include"),
        service_request_bundle_entry
      ]
    }
    result = with_http_bundle(bundle) { @adapter.list_referrals("pt_test_001") }

    assert_equal [ "sr_test_001" ], result.map(&:identifier)
  end

  def test_list_referrals_returns_empty_array_when_only_include_mode_patient_via_http
    bundle = {
      "resourceType" => "Bundle",
      "type" => "searchset",
      "entry" => [ patient_bundle_entry(mode: "include") ]
    }
    result = with_http_bundle(bundle) { @adapter.list_referrals("pt_test_001") }

    assert_equal [], result
  end

  def test_list_referrals_does_not_return_wrong_resource_type_match_entries_via_http
    bundle = {
      "resourceType" => "Bundle",
      "type" => "searchset",
      "entry" => [ patient_bundle_entry(mode: "match") ]
    }
    result = with_http_bundle(bundle) { @adapter.list_referrals("pt_test_001") }

    assert_equal [], result
  end

  def test_search_patients_omits_non_patient_match_entries_via_http
    bundle = {
      "resourceType" => "Bundle",
      "type" => "searchset",
      "entry" => [
        service_request_bundle_entry,
        patient_bundle_entry(mode: "match", id: "pt_match_001")
      ]
    }
    result = with_http_bundle(bundle) { @adapter.search_patients("TEST,PATIENT") }

    assert_equal [ "pt_match_001" ], result.map(&:identifier)
  end

  TRANSPORT_ERRORS.each do |error_class|
    LIST_READS.each_key do |method|
      define_method("test_#{method}_returns_nil_when_http_get_raises_#{error_class.name.split('::').last.downcase}") do
        arg = LIST_READS.fetch(method)
        result = with_http_error(error_class) { @adapter.public_send(method, arg) }

        assert_nil result, "#{method} must not raise on #{error_class}"
      end
    end
  end

  private

  def untyped_match_bundle_entry(method)
    case method
    when :search_patients
      patient_bundle_entry(mode: "match", id: "pt_untyped_match")
    when :search_practitioners
      practitioner_bundle_entry(mode: "match", id: "pr_untyped_match")
    when :list_referrals
      service_request_bundle_entry(id: "sr_untyped_match")
    when :list_claims
      claim_bundle_entry(item: [ {
        "sequence" => 1,
        "productOrService" => { "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ] },
        "net" => { "value" => 100.0, "currency" => "USD" }
      } ])
    when :get_care_team
      care_team_bundle_entry(id: "ct_untyped_match")
    else
      flunk "no untyped match fixture for #{method}"
    end
  end

  def with_http_bundle(bundle)
    response = http_response(bundle)
    @adapter.stub(:http_get, ->(_url) { response }) { yield }
  end

  def with_http_error(error_class)
    @adapter.stub(:http_get, ->(_url) { raise error_class }) { yield }
  end

  def http_response(body, status: 200)
    json_body = body.is_a?(String) ? body : JSON.generate(body)
    response_class = Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPOK
    response = response_class.new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, json_body)
    response.instance_variable_set(:@read, true)
    response
  end

  def patient_bundle_entry(mode:, id: "pt_include_001")
    {
      "resource" => {
        "resourceType" => "Patient",
        "id" => id,
        "name" => [ { "family" => "TEST", "given" => [ "PATIENT" ] } ]
      },
      "search" => { "mode" => mode }
    }
  end

  def practitioner_bundle_entry(mode: "match", id: "pr_test_001")
    {
      "resource" => {
        "resourceType" => "Practitioner",
        "id" => id,
        "name" => [ { "family" => "TEST", "given" => [ "PROVIDER" ] } ]
      },
      "search" => { "mode" => mode }
    }
  end

  def care_team_bundle_entry(id: "ct_test_001")
    {
      "resource" => {
        "resourceType" => "CareTeam",
        "id" => id,
        "status" => "active",
        "subject" => { "reference" => "Patient/pt_test_001" },
        "participant" => [
          { "member" => { "reference" => "Practitioner/pr_test_001" } }
        ]
      },
      "search" => { "mode" => "match" }
    }
  end

  def service_request_bundle_entry(id: "sr_test_001")
    {
      "resource" => {
        "resourceType" => "ServiceRequest",
        "id" => id,
        "status" => "active",
        "intent" => "order",
        "subject" => { "reference" => "Patient/pt_test_001" },
        "code" => { "text" => "Referral for testing" }
      },
      "search" => { "mode" => "match" }
    }
  end

  def claim_bundle_entry(item:)
    {
      "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_test_001",
        "patient" => { "reference" => "Patient/pt_test_001" },
        "provider" => { "reference" => "Organization/vend_test_001" },
        "item" => item
      },
      "search" => { "mode" => "match" }
    }
  end
end
