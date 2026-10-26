# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "json"
require "net/http"
require "uri"
require "active_support/all"
require "corvid/adapters/fhir_adapter"

# Chair spec (#607 / PR #656): OperationOutcome issue.code must be a plain-ASCII
# FHIR code token (/\\A[!-~]+(?: [!-~]+)*\\z/) or the read is unknown (nil).
class Corvid::Adapters::FhirAdapterOutcomeCodeTokenTest < Minitest::Test
  CONDITION_CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-category"

  OUTCOME_SEVERITIES = %w[fatal error warning information].freeze

  UNTRUSTED_ASCII_CODES = %w[
    suppressed incomplete too-costly timeout throttled too-long exception
  ].freeze

  # Malformed tokens that must fail closed even when today's normalisation would
  # leave a benign trusted code (fullwidth letters) or ignore invalid encoding.
  MALFORMED_OUTCOME_CODE_CASES = [
    [ "non-breaking hyphen in too-costly", "too\u2011costly" ],
    [ "fullwidth timeout", "ｔｉｍｅｏｕｔ" ],
    [ "no-break space after timeout", "timeout\u00A0" ],
    [ "zero-width space before timeout", "\u200Btimeout" ],
    [ "trailing space on processing", "processing " ],
    [ "empty code", "" ],
    [ "fullwidth letter in informational", "ｉnformational" ]
  ].freeze

  INEXACT_UNTRUSTED_ASCII_CODES = [
    "Suppressed",
    "incomplete ",
    " TOO-COSTLY",
    "Timeout"
  ].freeze

  UNICODE_PADDING_UNTRUSTED_CODES = [
    "incomplete\u00A0",
    "\u2003timeout",
    "throttled\u200B",
    "too-long\u3000",
    "\uFEFFsuppressed"
  ].freeze

  def setup
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
  end

  MALFORMED_OUTCOME_CODE_CASES.each_with_index do |(label, code), index|
    define_method("test_get_coverages_returns_nil_for_malformed_outcome_code_#{index}") do
      patient = "pt_malformed_cov_#{index}"
      coverage = sample_coverage(for_patient: patient)
      OUTCOME_SEVERITIES.each do |severity|
        bundle = coverage_bundle_with_outcome(coverage, code: code, severity: severity)
        stub_coverage_http(coverage_search_url(patient) => ok_json(bundle)) do
          assert_nil @adapter.get_coverages(patient),
                     "expected nil for malformed OperationOutcome code (#{label}) at #{severity}"
        end
      end
    end

    define_method("test_get_conditions_returns_nil_for_malformed_outcome_code_#{index}") do
      condition = sample_condition
      OUTCOME_SEVERITIES.each do |severity|
        bundle = clinical_bundle_with_outcome([ condition ], code: code, severity: severity)
        assert_nil get_conditions(bundle),
                   "expected nil for malformed OperationOutcome code (#{label}) at #{severity} on Condition search"
      end
    end

    define_method("test_get_medications_returns_nil_for_malformed_outcome_code_#{index}") do
      request = sample_medication_request
      OUTCOME_SEVERITIES.each do |severity|
        bundle = clinical_bundle_with_outcome([ request ], code: code, severity: severity)
        assert_nil get_medications(bundle),
                   "expected nil for malformed OperationOutcome code (#{label}) at #{severity} on MedicationRequest search"
      end
    end
  end

  def test_get_coverages_returns_nil_for_invalid_utf8_operation_outcome_code_at_any_severity
    coverage = sample_coverage(for_patient: "pt_u8_oo_cov")
    OUTCOME_SEVERITIES.each do |severity|
      body = coverage_bundle_http_body_with_outcome_code(
        patient_id: "pt_u8_oo_cov",
        coverage_id: coverage["id"],
        severity: severity,
        code_fragment: "timeout#{invalid_utf8_byte_sequence}"
      )
      stub_coverage_http(coverage_search_url("pt_u8_oo_cov") => ok_body(body)) do
        assert_nil @adapter.get_coverages("pt_u8_oo_cov"),
                   "expected nil for invalid UTF-8 OperationOutcome code at #{severity}"
      end
    end
  end

  def test_get_conditions_returns_nil_for_invalid_utf8_operation_outcome_code_at_any_severity
    OUTCOME_SEVERITIES.each do |severity|
      bundle = clinical_bundle_with_outcome(
        [ sample_condition ],
        code: "timeout#{invalid_utf8_byte_sequence}",
        severity: severity
      )
      assert_nil get_conditions(bundle),
                 "expected nil for invalid UTF-8 OperationOutcome code at #{severity} on Condition search"
    end
  end

  def test_get_medications_returns_nil_for_invalid_utf8_operation_outcome_code_at_any_severity
    OUTCOME_SEVERITIES.each do |severity|
      bundle = clinical_bundle_with_outcome(
        [ sample_medication_request ],
        code: "timeout#{invalid_utf8_byte_sequence}",
        severity: severity
      )
      assert_nil get_medications(bundle),
                 "expected nil for invalid UTF-8 OperationOutcome code at #{severity} on MedicationRequest search"
    end
  end

  def test_get_coverages_returns_nil_for_case_insensitive_untrusted_ascii_code_at_any_severity
    coverage = sample_coverage(for_patient: "pt_untrusted_ascii_cov")
    INEXACT_UNTRUSTED_ASCII_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = coverage_bundle_with_outcome(coverage, code: code, severity: severity)
        stub_coverage_http(coverage_search_url("pt_untrusted_ascii_cov") => ok_json(bundle)) do
          assert_nil @adapter.get_coverages("pt_untrusted_ascii_cov"),
                     "expected nil for untrusted ASCII token #{code.inspect} at #{severity}"
        end
      end
    end
  end

  def test_get_coverages_returns_nil_for_unicode_padded_untrusted_code_as_malformed_token
    coverage = sample_coverage(for_patient: "pt_unicode_malformed_cov")
    UNICODE_PADDING_UNTRUSTED_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = coverage_bundle_with_outcome(coverage, code: code, severity: severity)
        stub_coverage_http(coverage_search_url("pt_unicode_malformed_cov") => ok_json(bundle)) do
          assert_nil @adapter.get_coverages("pt_unicode_malformed_cov"),
                     "expected nil for non-ASCII-token padded code #{code.inspect} at #{severity}"
        end
      end
    end
  end

  def test_get_conditions_returns_nil_for_unicode_padded_untrusted_code_as_malformed_token
    condition = sample_condition
    UNICODE_PADDING_UNTRUSTED_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = clinical_bundle_with_outcome([ condition ], code: code, severity: severity)
        assert_nil get_conditions(bundle),
                   "expected nil for non-ASCII-token padded code #{code.inspect} at #{severity} on Condition search"
      end
    end
  end

  def test_get_medications_returns_nil_for_unicode_padded_untrusted_code_as_malformed_token
    request = sample_medication_request
    UNICODE_PADDING_UNTRUSTED_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = clinical_bundle_with_outcome([ request ], code: code, severity: severity)
        assert_nil get_medications(bundle),
                   "expected nil for non-ASCII-token padded code #{code.inspect} at #{severity} on MedicationRequest search"
      end
    end
  end

  def test_get_coverages_keeps_rows_for_plain_ascii_informational_at_information_severity
    coverage = sample_coverage(for_patient: "pt_info_cov")
    bundle = coverage_bundle_with_outcome(coverage, code: "informational", severity: "information")
    stub_coverage_http(coverage_search_url("pt_info_cov") => ok_json(bundle)) do
      result = @adapter.get_coverages("pt_info_cov")
      refute_nil result
      assert_equal 1, result.size
    end
  end

  def test_get_conditions_keeps_list_for_plain_ascii_informational_at_information_severity
    condition = sample_condition
    bundle = clinical_bundle_with_outcome([ condition ], code: "informational", severity: "information")
    results = get_conditions(bundle)
    refute_nil results
    assert_equal 1, results.size
  end

  def test_get_medications_keeps_list_for_plain_ascii_informational_at_information_severity
    request = sample_medication_request
    bundle = clinical_bundle_with_outcome([ request ], code: "informational", severity: "information")
    results = get_medications(bundle)
    refute_nil results
    assert_equal 1, results.size
  end

  def test_get_coverages_returns_nil_for_plain_ascii_untrusted_codes_at_any_severity
    coverage = sample_coverage(for_patient: "pt_plain_untrusted_cov")
    UNTRUSTED_ASCII_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = coverage_bundle_with_outcome(coverage, code: code, severity: severity)
        stub_coverage_http(coverage_search_url("pt_plain_untrusted_cov") => ok_json(bundle)) do
          assert_nil @adapter.get_coverages("pt_plain_untrusted_cov"),
                     "expected nil for untrusted code #{code} at #{severity}"
        end
      end
    end
  end

  private

  def invalid_utf8_byte_sequence
    "\xFF".b.force_encoding(Encoding::UTF_8)
  end

  def coverage_search_url(patient_identifier)
    query = URI.encode_www_form(beneficiary: "Patient/#{patient_identifier}")
    "#{@adapter.base_url}/Coverage?#{query}"
  end

  def sample_coverage(for_patient:)
    {
      "resourceType" => "Coverage",
      "id" => "cov_token_test",
      "status" => "active",
      "beneficiary" => { "reference" => "Patient/#{for_patient}" },
      "subscriberId" => "POL_TOKEN",
      "payor" => [ { "reference" => "Organization/cov_token_test", "display" => "TEST PAYER TOKEN" } ],
      "type" => { "coding" => [ { "code" => "MCDSC" } ] },
      "period" => { "start" => "2026-01-01", "end" => "2026-12-31" }
    }
  end

  def sample_condition
    {
      "resourceType" => "Condition",
      "id" => "cond_token_test",
      "subject" => { "reference" => "Patient/pt_token_clinical" },
      "category" => [ {
        "coding" => [ { "system" => CONDITION_CATEGORY_SYSTEM, "code" => "problem-list-item" } ]
      } ],
      "clinicalStatus" => { "coding" => [ { "code" => "active" } ] },
      "code" => {
        "coding" => [ { "system" => "http://example.test/codes", "code" => "C_TOKEN", "display" => "TEST CONDITION TOKEN" } ]
      },
      "onsetDateTime" => "2020-01-01"
    }
  end

  def sample_medication_request
    {
      "resourceType" => "MedicationRequest",
      "id" => "mr_token_test",
      "status" => "active",
      "subject" => { "reference" => "Patient/pt_token_clinical" },
      "authoredOn" => "2024-06-01",
      "medicationCodeableConcept" => {
        "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M_TOKEN", "display" => "TEST MED TOKEN" } ]
      },
      "dosageInstruction" => [ { "text" => "TEST DOSAGE TOKEN" } ]
    }
  end

  def coverage_bundle_with_outcome(coverage, code:, severity:)
    {
      "resourceType" => "Bundle",
      "type" => "searchset",
      "entry" => [
        {
          "resource" => {
            "resourceType" => "OperationOutcome",
            "issue" => [ { "severity" => severity, "code" => code } ]
          }
        },
        { "resource" => coverage }
      ]
    }
  end

  def coverage_bundle_http_body_with_outcome_code(patient_id:, coverage_id:, severity:, code_fragment:)
    %({
      "resourceType":"Bundle",
      "type":"searchset",
      "entry":[
        {"resource":{
          "resourceType":"OperationOutcome",
          "issue":[{"severity":"#{severity}","code":"#{code_fragment}"}]
        }},
        {"resource":{
          "resourceType":"Coverage",
          "id":"#{coverage_id}",
          "status":"active",
          "beneficiary":{"reference":"Patient/#{patient_id}"},
          "subscriberId":"POL_TOKEN",
          "payor":[{"reference":"Organization/#{coverage_id}","display":"TEST PAYER TOKEN"}],
          "type":{"coding":[{"code":"MCDSC"}]},
          "period":{"start":"2026-01-01","end":"2026-12-31"}
        }}
      ]
    })
  end

  def clinical_bundle_with_outcome(resources, code:, severity:)
    entries = resources.map { |r| { "resource" => r, "search" => { "mode" => "match" } } }
    entries << {
      "resource" => {
        "resourceType" => "OperationOutcome",
        "issue" => [ { "severity" => severity, "code" => code } ]
      }
    }
    { "resourceType" => "Bundle", "type" => "searchset", "entry" => entries }
  end

  def get_conditions(bundle)
    @adapter.stub(:fhir_search, bundle) { @adapter.get_conditions("pt_token_clinical") }
  end

  def get_medications(bundle)
    @adapter.stub(:fhir_search, bundle) { @adapter.get_medications("pt_token_clinical") }
  end

  def stub_coverage_http(responses_by_url)
    impl = lambda do |url|
      responses_by_url.fetch(url) { raise KeyError, "unexpected http_get URL: #{url}" }
    end
    @adapter.stub(:http_get, impl) { yield }
  end

  def ok_json(body_hash)
    ok_body(body_hash.to_json)
  end

  def ok_body(body)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |resp|
      resp.instance_variable_set(:@read, true)
      resp.instance_variable_set(:@body, body)
    end
  end
end
