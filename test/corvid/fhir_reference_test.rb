# frozen_string_literal: true

require "test_helper"

# Expected shared reader for FHIR relative references (issue #663).
class Corvid::FhirReferenceTest < ActiveSupport::TestCase
  test "id_from returns the id segment for a normal Type/id reference" do
    assert_equal "pt_test_001", Corvid::FhirReference.id_from("Patient/pt_test_001")
    assert_equal "pr_test_001", Corvid::FhirReference.id_from("Practitioner/pr_test_001")
  end

  test "id_from returns nil for empty or whitespace id segments" do
    assert_nil Corvid::FhirReference.id_from("Patient/")
    assert_nil Corvid::FhirReference.id_from("Patient/ ")
    assert_nil Corvid::FhirReference.id_from("Practitioner/")
    assert_nil Corvid::FhirReference.id_from("Practitioner/  ")
  end

  test "id_from returns nil for blank reference" do
    assert_nil Corvid::FhirReference.id_from(nil)
    assert_nil Corvid::FhirReference.id_from("")
  end

  test "id_from returns nil when reference has type only and no id segment" do
    assert_nil Corvid::FhirReference.id_from("Patient")
    assert_nil Corvid::FhirReference.id_from("Practitioner")
  end

  test "id_from returns id for versioned Type/id/_history/version references" do
    assert_equal "pt_hist_001", Corvid::FhirReference.id_from("Patient/pt_hist_001/_history/3")
    assert_equal "pr_hist_001", Corvid::FhirReference.id_from("Practitioner/pr_hist_001/_history/99")
  end

  test "id_from returns nil for absolute URLs contained references and extra path segments" do
    assert_nil Corvid::FhirReference.id_from("https://ehr.example/fhir/Patient/pt_abs_001")
    assert_nil Corvid::FhirReference.id_from("#contained1")
    assert_nil Corvid::FhirReference.id_from("Patient/pt_extra/extra_seg")
  end

  test "id_from returns nil for non-String reference values without raising" do
    assert_nil Corvid::FhirReference.id_from({ "reference" => "Patient/pt_hash_001" })
    assert_nil Corvid::FhirReference.id_from(42)
    assert_nil Corvid::FhirReference.id_from([ "Patient/pt_arr_001" ])
  end

  test "id_from enforces expected resource type when type keyword is given" do
    assert_equal "pt_type_001", Corvid::FhirReference.id_from("Patient/pt_type_001", type: "Patient")
    assert_equal "pr_type_001", Corvid::FhirReference.id_from("Practitioner/pr_type_001", type: "Practitioner")
    assert_nil Corvid::FhirReference.id_from("Practitioner/pr_type_001", type: "Patient")
    assert_nil Corvid::FhirReference.id_from("Patient/pt_type_001", type: "Practitioner")
  end

  test "id_from returns nil for invalid UTF-8 without raising" do
    ref = "Patient/pt_\xED\xB0\x80".dup.force_encoding("UTF-8")
    result = nil
    assert_nothing_raised { result = Corvid::FhirReference.id_from(ref) }
    assert_nil result
  end

  test "id_from rejects ids that violate FHIR id syntax after ASCII whitespace strip" do
    assert_equal "pt_test_001", Corvid::FhirReference.id_from("Patient/pt_test_001")
    assert_nil Corvid::FhirReference.id_from("Patient/pt_x?_format=json")
    assert_nil Corvid::FhirReference.id_from("Patient/pt_x#frag")
    assert_nil Corvid::FhirReference.id_from("Patient/%20")
    assert_nil Corvid::FhirReference.id_from("Patient/\u00A0pt_nbsp_001")
    long_id = "a" * 65
    assert_nil Corvid::FhirReference.id_from("Patient/#{long_id}")
  end

  PROVIDER_TYPES = [ "Practitioner", "PractitionerRole", "Organization" ].freeze

  test "id_from accepts provider types as a String or Array of allowed types" do
    assert_equal "pr_prov_001", Corvid::FhirReference.id_from("Practitioner/pr_prov_001", type: PROVIDER_TYPES)
    assert_equal "rol_prov_001", Corvid::FhirReference.id_from("PractitionerRole/rol_prov_001", type: PROVIDER_TYPES)
    assert_equal "org_prov_001", Corvid::FhirReference.id_from("Organization/org_prov_001", type: PROVIDER_TYPES)
    assert_nil Corvid::FhirReference.id_from("Patient/pt_wrong_prov", type: PROVIDER_TYPES)
    assert_nil Corvid::FhirReference.id_from("Device/dev_wrong_prov", type: PROVIDER_TYPES)
    assert_nil Corvid::FhirReference.id_from("RelatedPerson/rp_wrong_prov", type: PROVIDER_TYPES)
  end

  test "id_from resolves absolute references under base_url like relative Type/id" do
    base = "https://fhir.example.com/r4"
    assert_equal "pt_base_001", Corvid::FhirReference.id_from(
      "#{base}/Patient/pt_base_001", type: "Patient", base_url: base
    )
    assert_equal "pt_base_hist", Corvid::FhirReference.id_from(
      "#{base}/Patient/pt_base_hist/_history/2", type: "Patient", base_url: "#{base}/"
    )
    assert_nil Corvid::FhirReference.id_from(
      "https://other.example/fhir/Patient/pt_foreign", type: "Patient", base_url: base
    )
    assert_nil Corvid::FhirReference.id_from("Patient/pt_rel_only", type: "Patient", base_url: base)
  end
end
