# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "corvid/pas"

class Corvid::Pas::RequestBundleTest < Minitest::Test
  FIXTURES_DIR = File.expand_path("../../fixtures/pas", __dir__)

  URN_REFERENCE_KEYS = [
    "urn:uuid:00000000-0000-4000-8000-000000000002",
    "urn:uuid:00000000-0000-4000-8000-000000000003",
    "urn:uuid:00000000-0000-4000-8000-000000000004",
    "urn:uuid:00000000-0000-4000-8000-000000000005",
    "urn:uuid:00000000-0000-4000-8000-000000000006",
    "urn:uuid:00000000-0000-4000-8000-000000000007"
  ].freeze

  CLIENT_REFERENCE_KEYS = [
    "Patient/pat-test-1",
    "Organization/org-clinic-a",
    "Organization/org-payer-a",
    "Coverage/cov-test-1",
    "http://client.example.org/fhir/Condition/cond-test-1",
    "DocumentReference/doc-test-1"
  ].freeze

  TRANSITIVE_RESOURCE_TYPES = %w[
    Patient Organization Organization Coverage Condition DocumentReference
  ].freeze

  REJECTION_DIAGNOSTICS = {
    structure_bundle: "Input must be a FHIR Bundle resource.",
    value_bundle_type: "Bundle type must be collection.",
    required_entry: "Bundle must include at least one entry.",
    required_entry_element: "Each Bundle entry must include fullUrl and resource.",
    structure_first_entry: "The first Bundle entry must be a Claim resource.",
    duplicate: "The same resource must not appear twice in the Bundle.",
    not_found: "A reference in the Bundle could not be resolved.",
    invariant_full_url: "A Bundle entry fullUrl must match its resource type and id.",
    nesting: "A Bundle entry is nested too deeply to resolve."
  }.freeze

  FHIR_ELEMENT_NAME = /\A[a-z][A-Za-z0-9]*\z/

  STATIC_PHI_FORBIDDEN = [
    "TEST",
    "PATIENT 001",
    "1900-01-01",
    "MBR-TEST-0001"
  ].freeze

  class RaisingHash < Hash
    %i[[] fetch dig each].each do |method_name|
      define_method(method_name) do |*_args, **_kwargs, &_block|
        raise RuntimeError, "TEST,PATIENT 001 1900-01-01"
      end
    end
  end

  def setup
    Corvid.reset_configuration!
  end

  def teardown
    Corvid.reset_configuration!
  end

  def test_parse_urn_uuid_fixture_returns_parsed_claim_and_references
    bundle = load_fixture("request_bundle_urn_uuid")
    result = parse_silently(bundle)

    assert result.ok?
    assert_instance_of Corvid::Pas::RequestBundle::Parsed, result
    assert result.frozen?

    assert_equal "Claim", result.claim["resourceType"]
    assert_equal URN_REFERENCE_KEYS.sort, result.references.keys.sort
    assert result.references.frozen?

    assert_equal(
      [ "Patient", "pat-test-urn-1" ],
      resource_type_and_id(result.references.fetch(URN_REFERENCE_KEYS[0]))
    )
    assert_equal(
      [ "Organization", "org-clinic-urn-a" ],
      resource_type_and_id(result.references.fetch(URN_REFERENCE_KEYS[1]))
    )
    assert_equal(
      [ "Organization", "org-payer-urn-a" ],
      resource_type_and_id(result.references.fetch(URN_REFERENCE_KEYS[2]))
    )
    assert_equal(
      [ "Coverage", "cov-test-urn-1" ],
      resource_type_and_id(result.references.fetch(URN_REFERENCE_KEYS[3]))
    )
    assert_equal(
      [ "Condition", "cond-test-urn-1" ],
      resource_type_and_id(result.references.fetch(URN_REFERENCE_KEYS[4]))
    )
    assert_equal(
      [ "DocumentReference", "doc-test-urn-1" ],
      resource_type_and_id(result.references.fetch(URN_REFERENCE_KEYS[5]))
    )

    assert_equal TRANSITIVE_RESOURCE_TYPES, result.resources.map { |r| r["resourceType"] }
    assert result.resources.frozen?
  end

  def test_parse_client_url_fixture_resolves_relative_and_absolute_references
    bundle = load_fixture("request_bundle_client_urls")
    result = parse_silently(bundle)

    assert result.ok?
    assert_equal CLIENT_REFERENCE_KEYS.sort, result.references.keys.sort

    beneficiary = result.resources.find { |r| r["resourceType"] == "Coverage" }
    assert_equal "Patient/pat-test-1", beneficiary.dig("beneficiary", "reference")

    assert_equal(
      [ "Patient", "pat-test-1" ],
      resource_type_and_id(result.references.fetch("Patient/pat-test-1"))
    )
    assert_equal(
      [ "Condition", "cond-test-1" ],
      resource_type_and_id(
        result.references.fetch("http://client.example.org/fhir/Condition/cond-test-1")
      )
    )
  end

  def test_parsed_claim_and_references_are_deep_frozen_and_input_mutations_do_not_apply
    bundle = load_fixture("request_bundle_urn_uuid")
    original_patient_ref = bundle.dig("entry", 0, "resource", "patient", "reference")
    result = Corvid::Pas::RequestBundle.parse(bundle)

    bundle["entry"][0]["resource"]["patient"]["reference"] = "urn:uuid:dead"
    assert_equal original_patient_ref, result.claim.dig("patient", "reference")

    assert_raises(FrozenError) { result.claim["status"] = "cancelled" }
    assert_raises(FrozenError) { result.references[URN_REFERENCE_KEYS[0]] = {} }
    assert_raises(FrozenError) { result.resources << {} }
  end

  def test_parse_emits_no_stdout_or_stderr_on_success_or_rejection
    bundle = load_fixture("request_bundle_urn_uuid")
    broken = deep_copy(bundle)
    broken["entry"] = []

    assert_output("", "") { Corvid::Pas::RequestBundle.parse(bundle) }
    assert_output("", "") { Corvid::Pas::RequestBundle.parse(broken) }
  end

  def test_second_parse_is_unaffected_by_first
    urn = load_fixture("request_bundle_urn_uuid")
    client = load_fixture("request_bundle_client_urls")

    first = Corvid::Pas::RequestBundle.parse(urn)
    second = Corvid::Pas::RequestBundle.parse(client)

    assert first.ok?
    assert second.ok?
    assert_equal CLIENT_REFERENCE_KEYS.sort, second.references.keys.sort
  end

  def test_rejects_input_that_is_not_a_fhir_bundle
    rejected = Corvid::Pas::RequestBundle.parse("not-a-hash")
    assert_rejection(
      rejected,
      code: "structure",
      expression: "Bundle",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:structure_bundle),
      source_bundle: {}
    )

    rejected = Corvid::Pas::RequestBundle.parse({ "resourceType" => "Patient" })
    assert_rejection(
      rejected,
      code: "structure",
      expression: "Bundle",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:structure_bundle),
      source_bundle: { "resourceType" => "Patient" }
    )
  end

  def test_rejects_bundle_whose_type_is_not_collection
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["type"] = "searchset"

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "value",
      expression: "Bundle.type",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:value_bundle_type),
      source_bundle: bundle
    )
  end

  def test_rejects_bundle_with_missing_or_empty_entry
    base = load_fixture("request_bundle_urn_uuid")

    missing = deep_copy(base)
    missing.delete("entry")
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(missing),
      code: "required",
      expression: "Bundle.entry",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:required_entry),
      source_bundle: missing
    )

    empty = deep_copy(base)
    empty["entry"] = []
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(empty),
      code: "required",
      expression: "Bundle.entry",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:required_entry),
      source_bundle: empty
    )

    not_array = deep_copy(base)
    not_array["entry"] = "not-an-array"
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(not_array),
      code: "required",
      expression: "Bundle.entry",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:required_entry),
      source_bundle: not_array
    )
  end

  def test_rejects_bundle_entry_missing_full_url_or_resource
    base = load_fixture("request_bundle_urn_uuid")

    not_hash = deep_copy(base)
    not_hash["entry"][3] = "not-an-entry-hash"
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(not_hash),
      code: "required",
      expression: "Bundle.entry[3]",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:required_entry_element),
      source_bundle: not_hash
    )

    no_full_url = deep_copy(base)
    no_full_url["entry"][1].delete("fullUrl")
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(no_full_url),
      code: "required",
      expression: "Bundle.entry[1].fullUrl",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:required_entry_element),
      source_bundle: no_full_url
    )

    no_resource = deep_copy(base)
    no_resource["entry"][2].delete("resource")
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(no_resource),
      code: "required",
      expression: "Bundle.entry[2].resource",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:required_entry_element),
      source_bundle: no_resource
    )
  end

  def test_rejects_bundle_when_first_entry_is_not_a_claim
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"][0]["resource"]["resourceType"] = "Patient"

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "structure",
      expression: "Bundle.entry[0].resource",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:structure_first_entry),
      source_bundle: bundle
    )
  end

  def test_rejects_duplicate_full_url_in_entries
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    duplicate = deep_copy(bundle["entry"][1])
    bundle["entry"] << duplicate

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "duplicate",
      expression: "Bundle.entry[7]",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:duplicate),
      source_bundle: bundle
    )
  end

  def test_rejects_duplicate_resource_type_and_id_in_entries
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    extra = {
      "fullUrl" => "urn:uuid:99999999-9999-4999-8999-999999999999",
      "resource" => deep_copy(bundle["entry"][1]["resource"])
    }
    bundle["entry"] << extra

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "duplicate",
      expression: "Bundle.entry[7]",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:duplicate),
      source_bundle: bundle
    )
  end

  def test_rejects_unresolved_reference_in_claim
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"][0]["resource"]["patient"]["reference"] =
      "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.patient.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_rejects_unresolved_reference_in_transitively_referenced_coverage
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"][4]["resource"]["payor"][0]["reference"] =
      "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[4].resource.payor[0].reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_rejects_unmatched_contained_reference_in_claim
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    claim["contained"] = [
      { "resourceType" => "Provenance", "id" => "prov-inner-1" }
    ]
    claim["patient"] = { "reference" => "#prov-missing" }

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.patient.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_unexpected_internal_error_raises_sanitized_error_without_cause
    payload = RaisingHash.new
    payload.store("resourceType", "Bundle")

    error = assert_raises(Corvid::Pas::RequestBundle::Error) do
      Corvid::Pas::RequestBundle.parse(payload)
    end

    assert_equal "[REDACTED]", error.message
    refute_includes error.message, "PATIENT 001"
    assert_nil error.cause
  end

  def test_references_hold_only_the_claims_own_reference_strings
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"][4]["resource"]["subscriber"] = { "reference" => "Patient/pat-test-urn-1" }

    result = parse_silently(bundle)

    assert result.ok?
    assert_equal URN_REFERENCE_KEYS.sort, result.references.keys.sort
    assert_equal 1, result.resources.count { |r| r["resourceType"] == "Patient" }
  end

  def test_relative_reference_from_urn_entry_resolves_by_type_and_id
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"][0]["resource"]["patient"]["reference"] = "Patient/pat-test-urn-1"

    result = parse_silently(bundle)

    assert result.ok?
    patient = result.references.fetch("Patient/pat-test-urn-1")
    assert_equal [ "Patient", "pat-test-urn-1" ], resource_type_and_id(patient)
  end

  def test_history_reference_resolves_like_plain
    urn = deep_copy(load_fixture("request_bundle_urn_uuid"))
    urn_result = parse_silently(urn)
    assert urn_result.ok?
    assert_equal URN_REFERENCE_KEYS[0], urn.dig("entry", 0, "resource", "patient", "reference")

    client = deep_copy(load_fixture("request_bundle_client_urls"))
    history_ref = "Patient/pat-test-1/_history/2"
    client["entry"][0]["resource"]["patient"]["reference"] = history_ref

    result = parse_silently(client)

    assert result.ok?
    patient = result.references.fetch(history_ref)
    assert_equal [ "Patient", "pat-test-1" ], resource_type_and_id(patient)
  end

  def test_contained_reference_resolves_within_the_claim
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    contained_practitioner = { "resourceType" => "Practitioner", "id" => "prac-inner-1" }
    claim["contained"] = [ contained_practitioner ]
    claim["careTeam"] = [
      { "sequence" => 1, "provider" => { "reference" => "#prac-inner-1" } }
    ]

    result = parse_silently(bundle)

    assert result.ok?
    inner = result.references.fetch("#prac-inner-1")
    assert_equal [ "Practitioner", "prac-inner-1" ], resource_type_and_id(inner)
    refute result.resources.any? { |r| r["resourceType"] == "Practitioner" }
  end

  def test_logical_reference_without_reference_string_is_ignored
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    baseline = parse_silently(deep_copy(load_fixture("request_bundle_urn_uuid")))
    claim = bundle["entry"][0]["resource"]
    claim["referral"] = {
      "identifier" => {
        "system" => "http://example.org/referrals",
        "value" => "REF-TEST-1"
      }
    }

    result = parse_silently(bundle)

    assert result.ok?
    assert_equal baseline.references.keys.sort, result.references.keys.sort
  end

  def test_first_unresolved_reference_in_entry_then_document_order_wins
    missing = "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"

    entry_order = deep_copy(load_fixture("request_bundle_urn_uuid"))
    entry_order["entry"][0]["resource"]["insurer"]["reference"] = missing
    entry_order["entry"][4]["resource"]["payor"][0]["reference"] = missing
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(entry_order),
      code: "not-found",
      expression: "Bundle.entry[0].resource.insurer.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: entry_order
    )

    document_order = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = document_order["entry"][0]["resource"]
    claim["patient"]["reference"] = missing
    claim["insurance"][0]["coverage"]["reference"] = missing
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(document_order),
      code: "not-found",
      expression: "Bundle.entry[0].resource.patient.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: document_order
    )
  end

  def test_relative_reference_does_not_cross_to_another_base
    bundle = deep_copy(load_fixture("request_bundle_client_urls"))
    bundle["entry"] << {
      "fullUrl" => "http://other.example.org/fhir/Practitioner/prac-other-1",
      "resource" => {
        "resourceType" => "Practitioner",
        "id" => "prac-other-1"
      }
    }
    bundle["entry"][0]["resource"]["careTeam"] = [
      { "sequence" => 1, "provider" => { "reference" => "Practitioner/prac-other-1" } }
    ]

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.careTeam[0].provider.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_unreferenced_entries_are_not_in_resources
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    baseline = parse_silently(deep_copy(load_fixture("request_bundle_urn_uuid")))
    bundle["entry"] << {
      "fullUrl" => "urn:uuid:99999999-9999-4999-8999-999999999998",
      "resource" => {
        "resourceType" => "Practitioner",
        "id" => "prac-unused-1"
      }
    }

    result = parse_silently(bundle)

    assert result.ok?
    refute result.resources.any? { |r| r["resourceType"] == "Practitioner" }
    assert_equal baseline.references.keys.sort, result.references.keys.sort
  end

  def test_rejects_unresolved_reference_with_expression_stopped_before_non_fhir_object_key
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    claim["Jane Doe 1960-02-03"] = {
      "reference" => "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"
    }

    rejected = Corvid::Pas::RequestBundle.parse(bundle)
    assert_rejection(
      rejected,
      code: "not-found",
      expression: "Bundle.entry[0].resource",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )

    outcome_json = JSON.generate(rejected.operation_outcome)
    refute_includes outcome_json, "Jane"
    refute_includes outcome_json, "Doe"
    refute_includes outcome_json, "1960"
  end

  def test_rejects_unresolved_reference_with_expression_stopped_before_non_fhir_coverage_key
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    claim["insurance"] = [
      {
        "sequence" => 1,
        "focal" => true,
        "coverage" => {
          "PATIENT_001" => {
            "reference" => "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"
          }
        }
      }
    ]

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.insurance[0].coverage",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_rejects_invalid_encoding_in_object_key_without_raising
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    invalid_key = "\xFF".b
    claim["x"] = {
      invalid_key => {
        "reference" => "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"
      }
    }

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.x",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_rejects_invalid_encoding_in_reference_string_without_raising
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"][0]["resource"]["patient"] = { "reference" => "\xFF".b }

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.patient.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_rejects_restful_full_url_when_entry_resource_type_does_not_match
    bundle = deep_copy(load_fixture("request_bundle_client_urls"))
    bundle["entry"][1]["resource"]["resourceType"] = "Organization"

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "invariant",
      expression: "Bundle.entry[1].fullUrl",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:invariant_full_url),
      source_bundle: bundle
    )
  end

  def test_rejects_restful_full_url_when_entry_resource_id_does_not_match
    bundle = deep_copy(load_fixture("request_bundle_client_urls"))
    bundle["entry"][1]["resource"]["id"] = "pat-other"

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "invariant",
      expression: "Bundle.entry[1].fullUrl",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:invariant_full_url),
      source_bundle: bundle
    )
  end

  def test_rejects_duplicate_contained_resource_ids_within_claim
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    claim["contained"] = [
      { "resourceType" => "Practitioner", "id" => "dup-inner-1" },
      { "resourceType" => "Organization", "id" => "dup-inner-1" }
    ]
    claim["careTeam"] = [
      { "sequence" => 1, "provider" => { "reference" => "#dup-inner-1" } }
    ]

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "duplicate",
      expression: "Bundle.entry[0].resource.contained[1]",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:duplicate),
      source_bundle: bundle
    )
  end

  def test_rejects_claim_entry_when_reference_nesting_exceeds_limit
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    missing = "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"
    bundle["entry"][0]["resource"]["patient"] = deep_reference_node(70, missing)

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "structure",
      expression: "Bundle.entry[0]",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:nesting),
      source_bundle: bundle
    )
  end

  def test_resolves_deeply_nested_reference_when_within_nesting_limit
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    missing = "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"
    part_levels = 30
    bundle["entry"][0]["resource"]["patient"] = plain_part_reference_nest(part_levels, missing)
    assert_equal 32, json_containers_below_resource_to_reference(part_levels)

    part_suffix = ".part" * part_levels
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.patient#{part_suffix}.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_resolves_reference_when_nesting_is_at_json_container_limit
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    missing = "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"
    part_levels = json_container_part_levels_for_limit(64)
    bundle["entry"][0]["resource"]["patient"] = plain_part_reference_nest(part_levels, missing)
    assert_equal 64, json_containers_below_resource_to_reference(part_levels)

    part_suffix = ".part" * part_levels
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.patient#{part_suffix}.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_rejects_reference_when_nesting_exceeds_json_container_limit_by_one
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    missing = "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"
    part_levels = json_container_part_levels_for_limit(65)
    bundle["entry"][0]["resource"]["patient"] = plain_part_reference_nest(part_levels, missing)
    assert_equal 65, json_containers_below_resource_to_reference(part_levels)

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "structure",
      expression: "Bundle.entry[0]",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:nesting),
      source_bundle: bundle
    )
  end

  def test_rejects_unresolved_reference_inside_claim_contained_resource
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    claim["contained"] = [
      {
        "resourceType" => "Practitioner",
        "id" => "prac-inner-1",
        "qualification" => [
          {
            "issuer" => {
              "reference" => "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"
            }
          }
        ]
      }
    ]

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.contained[0].qualification[0].issuer.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_resolves_reference_inside_claim_contained_resource_to_bundle_entry
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    claim["contained"] = [
      {
        "resourceType" => "Practitioner",
        "id" => "prac-inner-1",
        "qualification" => [
          {
            "issuer" => {
              "reference" => URN_REFERENCE_KEYS[1]
            }
          }
        ]
      }
    ]

    result = parse_silently(bundle)

    assert result.ok?
    assert result.resources.any? { |r| r["resourceType"] == "Organization" && r["id"] == "org-clinic-urn-a" }
  end

  def test_contained_fragment_reference_does_not_resolve_against_other_entries_contained
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    claim["contained"] = [
      { "resourceType" => "Practitioner", "id" => "scope-inner-1" }
    ]
    bundle["entry"][4]["resource"]["subscriber"] = { "reference" => "#scope-inner-1" }

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[4].resource.subscriber.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_relative_type_id_does_not_resolve_when_entry_full_url_is_not_restful_or_urn_uuid
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"][0]["fullUrl"] = "urn:oid:2.16.840.1.113883.3.9999"
    bundle["entry"][0]["resource"]["patient"]["reference"] = "Patient/pat-test-urn-1"

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.patient.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_rejects_four_segment_reference_without_history_tail
    bundle = deep_copy(load_fixture("request_bundle_client_urls"))
    bundle["entry"][0]["resource"]["patient"]["reference"] = "Patient/pat-test-1/x/2"

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "not-found",
      expression: "Bundle.entry[0].resource.patient.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: bundle
    )
  end

  def test_parsed_result_deep_freezes_nested_reference_strings_and_resource_fields
    result = parse_silently(load_fixture("request_bundle_urn_uuid"))

    assert_raises(FrozenError) { result.claim["patient"]["reference"] = "x" }
    assert_raises(FrozenError) { result.claim["insurance"][0]["coverage"]["reference"] << "x" }
    assert_raises(FrozenError) { result.references.values.first["resourceType"] = "x" }
    assert_raises(FrozenError) { result.resources.first["id"] = "x" }
  end

  def test_parse_succeeds_with_many_supporting_info_document_reference_entries
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    baseline = parse_silently(deep_copy(load_fixture("request_bundle_urn_uuid")))
    baseline_resource_count = baseline.resources.size
    extra_count = 3000
    extra_supporting = []

    extra_count.times do |index|
      suffix = format("%012x", 0x1000 + index)
      full_url = "urn:uuid:00000000-0000-4000-8000-#{suffix}"
      doc_id = "doc-scale-#{index}"
      bundle["entry"] << {
        "fullUrl" => full_url,
        "resource" => {
          "resourceType" => "DocumentReference",
          "id" => doc_id,
          "status" => "current"
        }
      }
      extra_supporting << { "valueReference" => { "reference" => full_url } }
    end

    claim["supportingInfo"] = claim["supportingInfo"] + extra_supporting

    result = parse_silently(bundle)

    assert result.ok?
    assert_equal baseline_resource_count + extra_count, result.resources.size
  end

  def test_rejects_same_full_url_with_different_resources
    patient_full_url = URN_REFERENCE_KEYS[0]

    observation_dup = deep_copy(load_fixture("request_bundle_urn_uuid"))
    observation_dup["entry"] << {
      "fullUrl" => patient_full_url,
      "resource" => {
        "resourceType" => "Observation",
        "id" => "obs-dup-1",
        "status" => "final",
        "code" => { "text" => "x-obs" }
      }
    }
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(observation_dup),
      code: "duplicate",
      expression: "Bundle.entry[7]",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:duplicate),
      source_bundle: observation_dup
    )

    shared_full_url = "urn:uuid:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    two_patients = deep_copy(load_fixture("request_bundle_urn_uuid"))
    two_patients["entry"][0]["resource"]["patient"]["reference"] = shared_full_url
    two_patients["entry"] << {
      "fullUrl" => shared_full_url,
      "resource" => {
        "resourceType" => "Patient",
        "id" => "pat-dup-aaa1"
      }
    }
    two_patients["entry"] << {
      "fullUrl" => shared_full_url,
      "resource" => {
        "resourceType" => "Patient",
        "id" => "pat-dup-bbb2"
      }
    }
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(two_patients),
      code: "duplicate",
      expression: "Bundle.entry[8]",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:duplicate),
      source_bundle: two_patients
    )
  end

  def test_rejects_unresolved_reference_reachable_only_transitively
    prac_full_url = "urn:uuid:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    missing_issuer = "urn:uuid:ffffffff-ffff-4fff-8fff-ffffffffffff"

    unresolved = deep_copy(load_fixture("request_bundle_urn_uuid"))
    unresolved["entry"] << {
      "fullUrl" => prac_full_url,
      "resource" => {
        "resourceType" => "Practitioner",
        "id" => "prac-trans-1",
        "qualification" => [
          {
            "issuer" => { "reference" => missing_issuer }
          }
        ]
      }
    }
    unresolved["entry"][4]["resource"]["subscriber"] = { "reference" => prac_full_url }
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(unresolved),
      code: "not-found",
      expression: "Bundle.entry[7].resource.qualification[0].issuer.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: unresolved
    )

    resolved = deep_copy(load_fixture("request_bundle_urn_uuid"))
    baseline = parse_silently(deep_copy(load_fixture("request_bundle_urn_uuid")))
    resolved["entry"] << {
      "fullUrl" => prac_full_url,
      "resource" => {
        "resourceType" => "Practitioner",
        "id" => "prac-trans-1",
        "qualification" => [
          {
            "issuer" => { "reference" => URN_REFERENCE_KEYS[1] }
          }
        ]
      }
    }
    resolved["entry"][4]["resource"]["subscriber"] = { "reference" => prac_full_url }

    result = parse_silently(resolved)

    assert result.ok?
    assert_equal baseline.references.keys.sort, result.references.keys.sort
    refute result.references.key?(prac_full_url)
    assert result.resources.any? { |r| r["resourceType"] == "Practitioner" && r["id"] == "prac-trans-1" }
  end

  def test_rejects_malformed_reference_shapes
    [
      "Patient/pat-test-1/extra",
      " Patient/pat-test-1",
      "Patient/pat-test-1 ",
      "patient/pat-test-1"
    ].each do |bad_patient_ref|
      trial = deep_copy(load_fixture("request_bundle_client_urls"))
      trial["entry"][0]["resource"]["patient"]["reference"] = bad_patient_ref
      assert_rejection(
        Corvid::Pas::RequestBundle.parse(trial),
        code: "not-found",
        expression: "Bundle.entry[0].resource.patient.reference",
        diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
        source_bundle: trial
      )
    end

    contained_case = deep_copy(load_fixture("request_bundle_urn_uuid"))
    contained_claim = contained_case["entry"][0]["resource"]
    contained_claim["contained"] = [
      { "resourceType" => "Practitioner", "id" => "prac-case-1" }
    ]
    contained_claim["careTeam"] = [
      { "sequence" => 1, "provider" => { "reference" => "#PRAC-CASE-1" } }
    ]
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(contained_case),
      code: "not-found",
      expression: "Bundle.entry[0].resource.careTeam[0].provider.reference",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:not_found),
      source_bundle: contained_case
    )

    lowercase_bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    lowercase_bundle["resourceType"] = "bundle"
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(lowercase_bundle),
      code: "structure",
      expression: "Bundle",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:structure_bundle),
      source_bundle: lowercase_bundle
    )

    collection_type = deep_copy(load_fixture("request_bundle_urn_uuid"))
    collection_type["type"] = "Collection"
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(collection_type),
      code: "value",
      expression: "Bundle.type",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:value_bundle_type),
      source_bundle: collection_type
    )

    lowercase_claim = deep_copy(load_fixture("request_bundle_urn_uuid"))
    lowercase_claim["entry"][0]["resource"]["resourceType"] = "claim"
    assert_rejection(
      Corvid::Pas::RequestBundle.parse(lowercase_claim),
      code: "structure",
      expression: "Bundle.entry[0].resource",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:structure_first_entry),
      source_bundle: lowercase_claim
    )
  end

  def test_resources_are_deep_frozen_and_input_strings_untouched
    bundle = load_fixture("request_bundle_urn_uuid")
    org_name = bundle.dig("entry", 2, "resource", "name")
    refute org_name.frozen?

    result = parse_silently(bundle)

    assert result.ok?
    result.resources.each do |resource|
      assert resource.frozen?, "expected #{resource['resourceType']} resource to be frozen"
      assert resource["resourceType"].frozen?, "expected nested resourceType string to be frozen"
    end

    org = result.resources.find { |r| r["resourceType"] == "Organization" && r["id"] == "org-clinic-urn-a" }
    assert_raises(FrozenError) { org["name"] << "x" }

    refute bundle.dig("entry", 2, "resource", "name").frozen?
    bundle.dig("entry", 2, "resource", "name") << "mutated"
    refute bundle.frozen?
    refute bundle["entry"].frozen?
  end

  def test_transitive_only_resource_is_deep_frozen_and_input_untouched
    prac_full_url = "urn:uuid:cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"] << {
      "fullUrl" => prac_full_url,
      "resource" => {
        "resourceType" => "Practitioner",
        "id" => "prac-freeze-1",
        "name" => [ { "family" => "TESTFREEZE" } ]
      }
    }
    bundle["entry"][4]["resource"]["subscriber"] = { "reference" => prac_full_url }

    input_practitioner = bundle["entry"].last["resource"]
    refute input_practitioner.frozen?

    result = parse_silently(bundle)

    assert result.ok?
    practitioner = result.resources.find { |r| r["id"] == "prac-freeze-1" }
    refute_nil practitioner
    assert practitioner.frozen?
    assert practitioner["name"].frozen?
    assert practitioner["name"][0].frozen?
    assert_raises(FrozenError) { practitioner["name"][0]["family"] << "x" }

    refute input_practitioner.frozen?
    refute input_practitioner["name"].frozen?
  end

  def test_rejects_blank_full_url
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    bundle["entry"][2]["fullUrl"] = "   "

    assert_rejection(
      Corvid::Pas::RequestBundle.parse(bundle),
      code: "required",
      expression: "Bundle.entry[2].fullUrl",
      diagnostics: REJECTION_DIAGNOSTICS.fetch(:required_entry_element),
      source_bundle: bundle
    )
  end

  def test_parses_many_contained_resources
    bundle = deep_copy(load_fixture("request_bundle_urn_uuid"))
    claim = bundle["entry"][0]["resource"]
    baseline = parse_silently(deep_copy(load_fixture("request_bundle_urn_uuid")))
    contained_count = 3000
    contained = []
    care_team = []

    contained_count.times do |index|
      prac_id = "prac-many-#{index}"
      contained << { "resourceType" => "Practitioner", "id" => prac_id }
      care_team << { "sequence" => index + 1, "provider" => { "reference" => "##{prac_id}" } }
    end

    claim["contained"] = contained
    claim["careTeam"] = care_team

    result = parse_silently(bundle)

    assert result.ok?
    assert_equal baseline.references.keys.size + contained_count, result.references.keys.size
    assert_equal baseline.resources.size, result.resources.size
    contained_count.times do |index|
      assert result.references.key?("#prac-many-#{index}")
    end
  end

  private

  def load_fixture(name)
    JSON.parse(File.read(File.join(FIXTURES_DIR, "#{name}.json")))
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def parse_silently(bundle)
    result = nil
    assert_output("", "") { result = Corvid::Pas::RequestBundle.parse(bundle) }
    result
  end

  def resource_type_and_id(resource)
    [ resource["resourceType"], resource["id"] ]
  end

  def assert_rejection(rejected, code:, expression:, diagnostics:, source_bundle:)
    refute rejected.ok?
    assert_instance_of Corvid::Pas::RequestBundle::Rejected, rejected
    assert rejected.frozen?

    outcome = rejected.operation_outcome
    assert outcome.frozen?
    assert_equal "OperationOutcome", outcome["resourceType"]
    assert_equal 1, outcome["issue"].length

    issue = outcome["issue"].first
    assert_equal "error", issue["severity"]
    assert_equal code, issue["code"]
    assert_equal [ expression ], issue["expression"]
    assert_equal diagnostics, issue["diagnostics"]

    assert_operation_outcome_has_no_phi(rejected, source_bundle)
  end

  def assert_operation_outcome_has_no_phi(rejected, source_bundle)
    json = JSON.generate(rejected.operation_outcome)
    forbidden = STATIC_PHI_FORBIDDEN +
                bundle_sensitive_strings(source_bundle) +
                non_fhir_element_hash_keys(source_bundle)
    forbidden.uniq.each do |fragment|
      refute_includes json, fragment, "OperationOutcome leaked #{fragment.inspect}"
    end
  end

  def deep_reference_node(levels, reference)
    node = { "reference" => reference }
    levels.times { node = { "extension" => [ node ] } }
    node
  end

  # Plain Hash wrappers: patient.part…part.reference (no extension/array doubling).
  def plain_part_reference_nest(part_levels, reference)
    node = { "reference" => reference }
    part_levels.times { node = { "part" => node } }
    node
  end

  # Nesting limit counts JSON containers (each Hash or Array) below
  # Bundle.entry[i].resource; the resource root is not counted. Path to a
  # Reference under patient uses patient (1) + part_levels part Hashes +
  # the Reference object's Hash (1).
  def json_containers_below_resource_to_reference(part_levels)
    1 + part_levels + 1
  end

  def json_container_part_levels_for_limit(container_limit)
    container_limit - 2
  end

  def non_fhir_element_hash_keys(value)
    keys = []
    collect_non_fhir_element_hash_keys(value, keys)
    keys
  end

  def collect_non_fhir_element_hash_keys(value, keys)
    case value
    when Hash
      value.each_key do |key|
        keys << key if key.is_a?(String) && !key.match?(FHIR_ELEMENT_NAME)
        collect_non_fhir_element_hash_keys(value[key], keys)
      end
    when Array
      value.each { |child| collect_non_fhir_element_hash_keys(child, keys) }
    end
  end

  def bundle_sensitive_strings(bundle)
    return [] unless bundle.is_a?(Hash)

    strings = []
    collect_bundle_sensitive_strings(bundle, strings)
    strings
  end

  def collect_bundle_sensitive_strings(value, strings)
    case value
    when Hash
      strings << value["fullUrl"] if value["fullUrl"].is_a?(String)
      strings << value["reference"] if value["reference"].is_a?(String)
      strings << value["id"] if value["id"].is_a?(String)
      value.each_value { |child| collect_bundle_sensitive_strings(child, strings) }
    when Array
      value.each { |child| collect_bundle_sensitive_strings(child, strings) }
    end
  end
end
