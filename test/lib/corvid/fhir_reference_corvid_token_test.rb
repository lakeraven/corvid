# frozen_string_literal: true

require "test_helper"

# Corvid vault-token exception to strict FHIR id syntax (issue #663, chair decision A).
class Corvid::FhirReferenceCorvidTokenTest < ActiveSupport::TestCase
  PT_TOKEN = "pt_01HK8B7Z9XCQVG3F8N5K0R4MWB"
  PR_TOKEN = "pr_01HK8B7Z9XCQVG3F8N5K0R4MWC"
  RF_TOKEN = "rf_abc-1"

  test "id_from accepts Corvid pt_, pr_, and rf_ token ids on matching resource types" do
    assert_equal PT_TOKEN, Corvid::FhirReference.id_from("Patient/#{PT_TOKEN}", type: "Patient")
    assert_equal PR_TOKEN, Corvid::FhirReference.id_from("Practitioner/#{PR_TOKEN}", type: "Practitioner")
    assert_equal PR_TOKEN, Corvid::FhirReference.id_from("PractitionerRole/#{PR_TOKEN}", type: "PractitionerRole")
    assert_equal RF_TOKEN, Corvid::FhirReference.id_from("ServiceRequest/#{RF_TOKEN}", type: "ServiceRequest")
    assert_equal "pt_contract-001", Corvid::FhirReference.id_from("Patient/pt_contract-001", type: "Patient")
    assert_equal "pt_x", Corvid::FhirReference.id_from("Patient/pt_x")
  end

  test "id_from rejects Corvid token prefixes on the wrong resource type" do
    assert_nil Corvid::FhirReference.id_from("Patient/rf_01HK8B", type: "Patient")
    assert_nil Corvid::FhirReference.id_from("Patient/rf_01HK8B")
    assert_nil Corvid::FhirReference.id_from("Practitioner/pt_01HK8B", type: "Practitioner")
    assert_nil Corvid::FhirReference.id_from("Organization/pr_01HK8B", type: Corvid::FhirReference::PROVIDER_TYPES)
    assert_nil Corvid::FhirReference.id_from("ServiceRequest/pt_01HK8B", type: "ServiceRequest")
    assert_nil Corvid::FhirReference.id_from("Practitioner/rf_01HK8B", type: "Practitioner")
  end

  test "id_from accepts a pt_ Corvid token of exactly 64 characters and rejects 65" do
    ok_token = "pt_#{'a' * 61}"
    long_token = "pt_#{'a' * 62}"
    assert_equal 64, ok_token.length
    assert_equal 65, long_token.length
    assert_equal ok_token, Corvid::FhirReference.id_from("Patient/#{ok_token}", type: "Patient")
    assert_nil Corvid::FhirReference.id_from("Patient/#{long_token}", type: "Patient")
  end

  test "id_from returns nil for store_text nt_ prefix and strict _history version for Corvid-shaped ids" do
    assert_nil Corvid::FhirReference.id_from("Patient/nt_01HK8B", type: "Patient")
    assert_nil Corvid::FhirReference.id_from("Patient/pt-1/_history/pt_1")
    assert_equal "pt-1", Corvid::FhirReference.id_from("Patient/pt-1/_history/3")
  end

  test "id_from accepts versioned references when the resource id is a Corvid token" do
    assert_equal PT_TOKEN, Corvid::FhirReference.id_from("Patient/#{PT_TOKEN}/_history/3")
    assert_nil Corvid::FhirReference.id_from("Patient/#{PT_TOKEN}/_history/a b")
  end

  test "id_from rejects unknown prefixes, malformed Corvid tokens, and strict-syntax violations" do
    assert_nil Corvid::FhirReference.id_from("Patient/xx_abc")
    assert_nil Corvid::FhirReference.id_from("Patient/_abc")
    assert_nil Corvid::FhirReference.id_from("Patient/pt_")
    assert_nil Corvid::FhirReference.id_from("Patient/pt__abc")
    assert_nil Corvid::FhirReference.id_from("Patient/pt_a_b")
    assert_nil Corvid::FhirReference.id_from("Patient/PT_abc")
    assert_nil Corvid::FhirReference.id_from("Patient/pt_abc!")
    assert_nil Corvid::FhirReference.id_from("Patient/abc_def")
    long_pt = "pt_#{'a' * 62}"
    assert_nil Corvid::FhirReference.id_from("Patient/#{long_pt}")
  end

  test "id_from does not coerce Integer references" do
    assert_nil Corvid::FhirReference.id_from(42)
  end

  test "round-trip Corvid-emitted Patient reference preserves the pt_ token" do
    patient_identifier = PT_TOKEN
    reference = "Patient/#{patient_identifier}"
    assert_equal patient_identifier, Corvid::FhirReference.id_from(reference, type: "Patient")
  end

  test "FhirAdapter patient_reference? matches Corvid pt_ tokens" do
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
    assert adapter.send(:patient_reference?, "Patient/#{PT_TOKEN}", PT_TOKEN)
    refute adapter.send(:patient_reference?, "Patient/#{PT_TOKEN}", "pt-other")
    refute adapter.send(:patient_reference?, "Patient/pt-other", PT_TOKEN)
  end

  test "FhirAdapter patient_reference? rejects rf_ token on Patient reference" do
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
    refute adapter.send(:patient_reference?, "Patient/rf_01HK8BXYZ", "rf_01HK8BXYZ")
  end

  test "Task.from_fhir_attributes omits assignee when owner Practitioner reference uses pt_ token" do
    fhir_resource = OpenStruct.new(
      status: "requested",
      intent: "order",
      owner: OpenStruct.new(reference: "Practitioner/pt_01HK8C")
    )
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    refute attrs.key?(:assignee_identifier)
  end

  test "Task.from_fhir_attributes extracts assignee when owner Practitioner reference uses pr_ token" do
    fhir_resource = OpenStruct.new(
      status: "requested",
      intent: "order",
      owner: OpenStruct.new(reference: "Practitioner/#{PR_TOKEN}")
    )
    attrs = Corvid::Task.from_fhir_attributes(fhir_resource)
    assert_equal PR_TOKEN, attrs[:assignee_identifier]
  end
end
