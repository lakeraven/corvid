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
end
