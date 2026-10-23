# frozen_string_literal: true

require "test_helper"

# Expected shared reader for FHIR relative references (issue #663).
class Corvid::FhirReferenceTest < ActiveSupport::TestCase
  test "id_from returns the id segment for a normal Type/id reference" do
    assert_equal "pt-test-001", Corvid::FhirReference.id_from("Patient/pt-test-001")
    assert_equal "pr-test-001", Corvid::FhirReference.id_from("Practitioner/pr-test-001")
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
    assert_equal "pt-hist-001", Corvid::FhirReference.id_from("Patient/pt-hist-001/_history/3")
    assert_equal "pr-hist-001", Corvid::FhirReference.id_from("Practitioner/pr-hist-001/_history/99")
  end

  test "id_from returns nil when _history version segment violates FHIR id syntax" do
    assert_nil Corvid::FhirReference.id_from("Patient/pt-1/_history/a b?c")
    assert_nil Corvid::FhirReference.id_from("Patient/pt-1/_history/")
    assert_equal "pt-1", Corvid::FhirReference.id_from("Patient/pt-1/_history/3")
  end

  test "id_from returns nil for absolute URLs contained references and extra path segments" do
    assert_nil Corvid::FhirReference.id_from("https://ehr.example/fhir/Patient/pt-abs-001")
    assert_nil Corvid::FhirReference.id_from("#contained1")
    assert_nil Corvid::FhirReference.id_from("Patient/pt-extra/extra_seg")
  end

  test "id_from returns nil for non-String reference values without raising" do
    assert_nil Corvid::FhirReference.id_from({ "reference" => "Patient/pt-hash-001" })
    assert_nil Corvid::FhirReference.id_from(42)
    assert_nil Corvid::FhirReference.id_from([ "Patient/pt-arr-001" ])
  end

  test "id_from enforces expected resource type when type keyword is given" do
    assert_equal "pt-type-001", Corvid::FhirReference.id_from("Patient/pt-type-001", type: "Patient")
    assert_equal "pr-type-001", Corvid::FhirReference.id_from("Practitioner/pr-type-001", type: "Practitioner")
    assert_nil Corvid::FhirReference.id_from("Practitioner/pr-type-001", type: "Patient")
    assert_nil Corvid::FhirReference.id_from("Patient/pt-type-001", type: "Practitioner")
  end

  test "id_from returns nil for invalid UTF-8 without raising" do
    ref = "Patient/pt-\xED\xB0\x80".dup.force_encoding("UTF-8")
    result = nil
    assert_nothing_raised { result = Corvid::FhirReference.id_from(ref) }
    assert_nil result
  end

  test "id_from rejects ids that violate FHIR id syntax after ASCII whitespace strip" do
    assert_nil Corvid::FhirReference.id_from("Patient/pt_x")
    assert_nil Corvid::FhirReference.id_from("Patient/pt-x?_format=json")
    assert_nil Corvid::FhirReference.id_from("Patient/pt-x#frag")
    assert_nil Corvid::FhirReference.id_from("Patient/%20")
    assert_nil Corvid::FhirReference.id_from("Patient/\u00A0pt-nbsp-001")
    ok_id = "a" * 64
    long_id = "a" * 65
    assert_equal ok_id, Corvid::FhirReference.id_from("Patient/#{ok_id}")
    assert_nil Corvid::FhirReference.id_from("Patient/#{long_id}")
  end

  PROVIDER_TYPES = [ "Practitioner", "PractitionerRole", "Organization" ].freeze

  test "id_from accepts provider types as a String or Array of allowed types" do
    assert_equal "pr-prov-001", Corvid::FhirReference.id_from("Practitioner/pr-prov-001", type: PROVIDER_TYPES)
    assert_equal "rol-prov-001", Corvid::FhirReference.id_from("PractitionerRole/rol-prov-001", type: PROVIDER_TYPES)
    assert_equal "org-prov-001", Corvid::FhirReference.id_from("Organization/org-prov-001", type: PROVIDER_TYPES)
    assert_nil Corvid::FhirReference.id_from("Patient/pt-wrong-prov", type: PROVIDER_TYPES)
    assert_nil Corvid::FhirReference.id_from("Device/dev-wrong-prov", type: PROVIDER_TYPES)
    assert_nil Corvid::FhirReference.id_from("RelatedPerson/rp-wrong-prov", type: PROVIDER_TYPES)
  end

  test "id_from never raises for non-ASCII-compatible String encodings" do
    patient_id = "pt-enc-ref-001"
    base = "https://fhir.example.com/r4"
    %w[UTF-16LE UTF-16BE UTF-32LE UTF-32BE].each do |encoding|
      ref = "Patient/#{patient_id}".encode(encoding)
      result = nil
      assert_nothing_raised { result = Corvid::FhirReference.id_from(ref) }
      assert_equal patient_id, result, "expected id from #{encoding} relative reference"

      versioned = "Patient/#{patient_id}/_history/4".encode(encoding)
      assert_nothing_raised { result = Corvid::FhirReference.id_from(versioned) }
      assert_equal patient_id, result, "expected id from #{encoding} versioned reference"

      absolute = "#{base}/Patient/#{patient_id}/_history/4".encode(encoding)
      assert_nothing_raised do
        result = Corvid::FhirReference.id_from(absolute, type: "Patient", base_url: base)
      end
      assert_equal patient_id, result, "expected id from #{encoding} absolute reference under base_url"

      utf16_base = base.encode("UTF-16LE")
      assert_nothing_raised do
        result = Corvid::FhirReference.id_from(ref, type: "Patient", base_url: utf16_base)
      end
      assert_nil result, "UTF-16 base_url must yield nil (#{encoding} reference)"
    end
  end

  test "id_from returns nil without raising when base_url and reference encodings are incompatible" do
    non_ascii_base = "https://\u00E9x"
    w1252_absolute = "#{non_ascii_base}/Patient/pt-w1252".encode("Windows-1252")
    result = nil
    assert_nothing_raised do
      result = Corvid::FhirReference.id_from(w1252_absolute, type: "Patient", base_url: non_ascii_base)
    end
    assert_nil result

    ascii_base = "https://fhir.example.com/r4"
    utf8_ref = "Patient/pt-\u00E9mix"
    assert_nothing_raised do
      result = Corvid::FhirReference.id_from(utf8_ref, type: "Patient", base_url: ascii_base)
    end
    assert_nil result
  end

  test "id_from resolves absolute references under base_url like relative Type/id" do
    base = "https://fhir.example.com/r4"
    assert_equal "pt-base-001", Corvid::FhirReference.id_from(
      "#{base}/Patient/pt-base-001", type: "Patient", base_url: base
    )
    assert_equal "pt-base-hist", Corvid::FhirReference.id_from(
      "#{base}/Patient/pt-base-hist/_history/2", type: "Patient", base_url: "#{base}/"
    )
    assert_nil Corvid::FhirReference.id_from(
      "https://other.example/fhir/Patient/pt-foreign", type: "Patient", base_url: base
    )
    assert_nil Corvid::FhirReference.id_from("Patient/pt-rel-only", type: "Patient", base_url: base)
  end
end
