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
end
