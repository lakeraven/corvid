# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "net/http"
require "uri"
require "active_support/all" # adapter uses AS ext (Time.current, String#last, present?); loaded by the host app in real use
require "corvid/adapters/fhir_adapter"

class Corvid::Adapters::FhirAdapterTest < Minitest::Test
  def setup
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
  end

  def test_initializes_with_base_url
    assert_equal "https://fhir.example.com/r4", @adapter.base_url
  end

  def test_strips_trailing_slash_from_base_url
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4/")
    assert_equal "https://fhir.example.com/r4", adapter.base_url
  end

  def test_implements_all_base_methods
    base_methods = Corvid::Adapters::Base.instance_methods(false)
    base_methods.each do |method|
      assert_respond_to @adapter, method, "FhirAdapter must respond to Base##{method}"
    end
  end

  def test_find_patient_maps_to_patient_reference
    resource = {
      "id" => "pt_001",
      "birthDate" => "1980-01-01",
      "gender" => "female",
      "name" => [ { "family" => "TEST", "given" => [ "PATIENT" ] } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.find_patient("pt_001")
      assert_instance_of Corvid::PatientReference, result
      assert_equal "pt_001", result.identifier
      assert_equal "TEST, PATIENT", result.display_name
    end
  end

  def test_find_practitioner_includes_specialty
    resource = {
      "id" => "pr_001",
      "name" => [ { "family" => "TEST", "given" => [ "PROVIDER" ] } ],
      "qualification" => [ { "code" => { "coding" => [ { "display" => "Test Specialty" } ] } } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.find_practitioner("pr_001")
      assert_instance_of Corvid::PractitionerReference, result
      assert_equal "Test Specialty", result.specialty
    end
  end

  def test_find_referral_returns_complete_referral_reference
    resource = {
      "id" => "rf_001",
      "status" => "active",
      "priority" => "urgent",
      "subject" => { "reference" => "Patient/pt_001" }
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.find_referral("rf_001")
      assert_instance_of Corvid::ReferralReference, result
      assert_equal "rf_001", result.identifier
      assert_equal "pt_001", result.patient_identifier
      assert result.urgent?
      refute result.emergent?
    end
  end

  def test_find_referral_falls_back_from_blank_code_text_to_coding_display
    resource = {
      "id" => "rf_blank_text",
      "status" => "active",
      "subject" => { "reference" => "Patient/pt_001" },
      "code" => {
        "text" => "",
        "coding" => [ { "display" => "TEST,SERVICE 001" } ]
      }
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.find_referral("rf_blank_text")
      assert_equal "TEST,SERVICE 001", result.service_requested
    end
  end

  def test_list_claims_skips_blank_provider_identifier_value_for_reference_id
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_pr_blank_id",
        "patient" => { "reference" => "Patient/pt_pr" },
        "provider" => {
          "identifier" => { "value" => "" },
          "reference" => "Practitioner/pr_001"
        },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => { "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ] },
          "net" => { "value" => 100.0, "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      line = @adapter.list_claims("pt_pr").first
      assert_equal "pr_001", line.provider_identifier
    end
  end

  def test_list_claims_skips_blank_provider_reference_for_display
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_pr_blank_ref",
        "patient" => { "reference" => "Patient/pt_pr2" },
        "provider" => {
          "identifier" => { "value" => "" },
          "reference" => "",
          "display" => "TEST PROVIDER DISPLAY"
        },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => { "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ] },
          "net" => { "value" => 100.0, "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      line = @adapter.list_claims("pt_pr2").first
      assert_equal "TEST PROVIDER DISPLAY", line.provider_identifier
    end
  end

  def test_list_claims_skips_whitespace_provider_reference_id_for_display
    line = list_claim_with_provider(
      "identifier" => { "value" => "" },
      "reference" => "Practitioner/ ",
      "display" => "TEST PROVIDER DISPLAY"
    )
    assert_equal "TEST PROVIDER DISPLAY", line.provider_identifier
  end

  def test_list_claims_skips_empty_provider_reference_id_for_display
    line = list_claim_with_provider(
      "identifier" => { "value" => "" },
      "reference" => "Practitioner/",
      "display" => "TEST PROVIDER DISPLAY"
    )
    assert_equal "TEST PROVIDER DISPLAY", line.provider_identifier
  end

  def test_list_claims_provider_identifier_nil_when_all_provider_fields_blank
    line = list_claim_with_provider(
      "identifier" => { "value" => "" },
      "reference" => "",
      "display" => " "
    )
    assert_nil line.provider_identifier
  end

  def test_list_claims_procedure_display_nil_when_all_label_fallbacks_blank
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_all_blank_disp",
        "patient" => { "reference" => "Patient/pt_blank_disp" },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => {
            "text" => "   ",
            "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213", "display" => "" } ]
          },
          "net" => { "value" => 100.0, "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      line = @adapter.list_claims("pt_blank_disp").first
      assert_nil line.procedure_display
    end
  end

  def test_find_referral_service_requested_nil_when_code_labels_all_blank
    resource = {
      "id" => "rf_all_blank_svc",
      "status" => "active",
      "subject" => { "reference" => "Patient/pt_001" },
      "code" => {
        "text" => "",
        "coding" => [ { "display" => "   ", "code" => "" } ]
      }
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.find_referral("rf_all_blank_svc")
      assert_nil result.service_requested
    end
  end

  def test_list_claims_falls_back_procedure_display_from_product_or_service_text
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_blank_disp",
        "patient" => { "reference" => "Patient/pt_disp" },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => {
            "text" => "TEST,CLAIM LINE 001",
            "coding" => [
              { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213", "display" => "" }
            ]
          },
          "net" => { "value" => 100.0, "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      line = @adapter.list_claims("pt_disp").first
      assert_equal "TEST,CLAIM LINE 001", line.procedure_display
    end
  end

  def test_update_referral_whitelists_safe_fields
    existing = { "resourceType" => "ServiceRequest", "id" => "rf_001", "status" => "draft", "subject" => { "reference" => "Patient/pt_001" } }
    captured = nil
    @adapter.stub(:fhir_read, existing) do
      @adapter.stub(:fhir_update, ->(_t, _id, body) { captured = body; true }) do
        @adapter.update_referral("rf_001", status: "active", subject: { reference: "Patient/HACKED" }, resourceType: "EVIL")
      end
    end
    # subject and resourceType must NOT be merged
    assert_equal "active", captured["status"]
    assert_equal({ "reference" => "Patient/pt_001" }, captured["subject"])
    assert_equal "ServiceRequest", captured["resourceType"]
  end

  def test_update_referral_stores_committee_fields_as_extensions
    existing = { "resourceType" => "ServiceRequest", "id" => "rf_001", "status" => "active", "subject" => { "reference" => "Patient/pt_001" } }
    captured = nil
    @adapter.stub(:fhir_read, existing) do
      @adapter.stub(:fhir_update, ->(_t, _id, body) { captured = body; true }) do
        @adapter.update_referral("rf_001", chs_approval_status: "A", committee_decision: "APPROVED", approved_amount: 75_000)
      end
    end
    assert_equal "A", captured["chs_approval_status"]
    extensions = captured["extension"] || []
    assert(extensions.any? { |e| e["url"]&.include?("committee-decision") })
    assert(extensions.any? { |e| e["url"]&.include?("approved-amount") })
  end

  def test_list_claims_selects_cpt_coding_not_first_coding
    # A claim line can carry multiple codings (e.g. a SNOMED clinical code
    # first, then the billed CPT). The adapter must pick the CPT/HCPCS coding
    # for the procedure_code, not blindly take index 0.
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_1",
        "patient" => { "reference" => "Patient/pt_1" },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => { "coding" => [
            { "system" => "http://snomed.info/sct", "code" => "271737000", "display" => "SNOMED thing" },
            { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213", "display" => "Office visit" }
          ] },
          "net" => { "value" => 240.0, "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      lines = @adapter.list_claims("pt_1")
      assert_equal 1, lines.size
      assert_equal "99213", lines.first.procedure_code, "must select the CPT coding, not the SNOMED at index 0"
    end
  end

  def test_list_claims_selects_hcpcs_coding_over_non_billing_first
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_2",
        "patient" => { "reference" => "Patient/pt_2" },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => { "coding" => [
            { "system" => "http://loinc.org", "code" => "1234-5" },
            { "system" => "urn:oid:2.16.840.1.113883.6.285", "code" => "J1885" }
          ] },
          "net" => { "value" => 50.0, "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      assert_equal "J1885", @adapter.list_claims("pt_2").first.procedure_code
    end
  end

  def test_list_claims_falls_back_to_first_coding_when_no_billing_system
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_3",
        "patient" => { "reference" => "Patient/pt_3" },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => { "coding" => [ { "system" => "http://snomed.info/sct", "code" => "999" } ] },
          "net" => { "value" => 10.0, "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      assert_equal "999", @adapter.list_claims("pt_3").first.procedure_code
    end
  end

  def test_list_claims_flags_present_but_unparseable_amount
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_4",
        "patient" => { "reference" => "Patient/pt_4" },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => { "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ] },
          "net" => { "value" => "not-a-number", "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      line = @adapter.list_claims("pt_4").first
      assert_nil line.billed_amount, "unparseable amount does not become a bogus number"
      refute_nil line.amount_error, "present-but-unparseable amount is surfaced, not silently swallowed"
    end
  end

  def test_list_claims_absent_amount_is_legit_nil_without_error
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_5",
        "patient" => { "reference" => "Patient/pt_5" },
        "item" => [ {
          "sequence" => 1,
          "productOrService" => { "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ] }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      line = @adapter.list_claims("pt_5").first
      assert_nil line.billed_amount
      assert_nil line.amount_error, "absent amount is a legit nil, not an error"
    end
  end

  def test_list_claims_serviced_date_from_period_when_serviced_date_blank
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_blank_serviced_date",
        "patient" => { "reference" => "Patient/pt_serviced" },
        "item" => [ {
          "sequence" => 1,
          "servicedDate" => "",
          "servicedPeriod" => { "start" => "2026-01-05" },
          "productOrService" => { "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ] }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) do
      line = @adapter.list_claims("pt_serviced").first
      assert_equal Date.new(2026, 1, 5), line.serviced_date
    end
  end

  def test_coverage_type_map_covers_all_resource_types
    resource_types = %w[
      medicare_a medicare_b medicare_d medicaid va_benefits
      private_insurance workers_comp auto_insurance liability_coverage
      state_program tribal_program charity_care
    ]
    map = Corvid::Adapters::FhirAdapter::COVERAGE_TYPE_MAP
    resource_types.each do |rt|
      assert map.key?(rt), "COVERAGE_TYPE_MAP should include '#{rt}'"
    end
  end

  def test_store_text_uses_extension_kind
    # FhirAdapter stores text via DocumentReference extension; for v1 we
    # accept that the implementation may delegate to a vault. Default impl
    # raises NotImplementedError until production wires a real text vault.
    assert_raises(NotImplementedError) do
      @adapter.store_text(case_token: "ct_x", kind: :note, text: "TEST")
    end
  end

  def test_create_obligation_fails_closed_without_a_budget_backend
    # Stock FHIR has no budget concept, so the encumbrance write must not
    # report success: a `true` here would let an authorization proceed with
    # an obligation that was never recorded against any CHS budget.
    assert_raises(NotImplementedError) do
      @adapter.create_obligation("ref_001", 1500.00)
    end
  end

  # -- Tribal enrollment / identity / residency (read from Patient extensions) --

  def test_verify_tribal_enrollment_reads_extension
    resource = {
      "id" => "pt_001",
      "extension" => [ {
        "url" => "https://lakeraven.com/fhir/StructureDefinition/tribal-enrollment",
        "extension" => [
          { "url" => "enrolled", "valueBoolean" => true },
          { "url" => "membershipNumber", "valueString" => "TGN-100254" },
          { "url" => "tribeName", "valueString" => "Tallgrass Nation" },
          { "url" => "tribeCode", "valueString" => "TGN" },
          { "url" => "confidence", "valueString" => "verified" }
        ]
      } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_001")
      assert_equal true, result[:enrolled]
      assert_equal "TGN-100254", result[:membership_number]
      assert_equal "TGN", result[:tribe_code]
      assert_equal :verified, result[:confidence]
    end
  end

  def test_verify_tribal_enrollment_falls_back_when_extension_absent
    # Plain FHIR servers with no tribal-enrollment extension degrade to the
    # same fail-closed "unavailable" shape as before this method read FHIR.
    @adapter.stub(:fhir_read, { "id" => "pt_001" }) do
      result = @adapter.verify_tribal_enrollment("pt_001")
      assert_equal false, result[:enrolled]
      assert_equal :unavailable, result[:confidence]
    end
  end

  def test_verify_identity_documents_derives_from_patient_resource
    resource = {
      "id" => "pt_001",
      "birthDate" => "1978-11-02",
      "identifier" => [ { "system" => "http://hl7.org/fhir/sid/us-ssn", "value" => "555-01-0054" } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_identity_documents("pt_001")
      assert_equal true, result[:ssn_present]
      assert_equal true, result[:dob_present]
      assert_equal false, result[:birthplace_present]
    end
  end

  def test_verify_residency_reads_extension_and_address
    resource = {
      "id" => "pt_001",
      "address" => [ { "line" => [ "100 Main St" ], "city" => "Broken Rock", "state" => "WA" } ],
      "extension" => [ {
        "url" => "https://lakeraven.com/fhir/StructureDefinition/residency",
        "extension" => [
          { "url" => "onReservation", "valueBoolean" => true },
          { "url" => "serviceArea", "valueString" => "Broken Rock Health Center" }
        ]
      } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_residency("pt_001")
      assert_equal true, result[:on_reservation]
      assert_equal "100 Main St, Broken Rock, WA", result[:address]
      assert_equal "Broken Rock Health Center", result[:service_area]
    end
  end

  # -- get_conditions / get_medications (issue #611) --------------------------

  CONDITION_CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-category"

  def test_get_conditions_requests_condition_search_with_patient_query
    bundle = conditions_bundle([])
    url_seen = nil
    expected = "#{@adapter.base_url}/Condition?#{URI.encode_www_form(patient: "pt_001")}"

    @adapter.stub(:http_get, ->(url) { url_seen = url; consumed_http_response(bundle) }) do
      @adapter.get_conditions("pt_001")
    end

    assert_equal expected, url_seen
  end

  def test_get_conditions_maps_active_problem_list_item
    condition = build_condition_resource(
      code: { "coding" => [ { "system" => "http://example.test/codes", "code" => "C001", "display" => "TEST CONDITION 001" } ] },
      onsetDateTime: "2020-03-15T10:00:00Z"
    )
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    ref = results.first
    assert_instance_of Corvid::ConditionReference, ref
    assert_equal "C001", ref.code
    assert_equal "http://example.test/codes", ref.code_system
    assert_equal "TEST CONDITION 001", ref.display
    assert_equal "active", ref.clinical_status
    assert_equal "problem-list-item", ref.category
    assert_equal Date.new(2020, 3, 15), ref.onset_date
  end

  def test_get_conditions_includes_encounter_diagnosis_category
    condition = build_condition_resource(
      category_code: "encounter-diagnosis",
      clinical_status: "resolved"
    )
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    assert_equal "encounter-diagnosis", results.first.category
    assert_equal "resolved", results.first.clinical_status
  end

  def test_get_conditions_skips_non_us_core_category
    included = build_condition_resource
    skipped = build_condition_resource(category_code: "health-concern")
    results = get_conditions_with_bundle(conditions_bundle([ included, skipped ]))

    assert_equal 1, results.size
    assert_equal "problem-list-item", results.first.category
  end

  def test_get_conditions_skips_non_active_or_resolved_clinical_status
    included = build_condition_resource(clinical_status: "resolved")
    skipped = build_condition_resource(clinical_status: "inactive")
    results = get_conditions_with_bundle(conditions_bundle([ included, skipped ]))

    assert_equal 1, results.size
    assert_equal "resolved", results.first.clinical_status
  end

  def test_get_conditions_display_falls_back_to_code_text
    condition = build_condition_resource(
      code: { "text" => "TEST CONDITION 001", "coding" => [ { "system" => "http://example.test/codes", "code" => "C001", "display" => "" } ] }
    )
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    assert_equal "TEST CONDITION 001", results.first.display
  end

  def test_get_conditions_onset_date_from_onset_period_start
    condition = build_condition_resource(onsetDateTime: nil, onsetPeriod: { "start" => "2019-07-01" })
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    assert_equal Date.new(2019, 7, 1), results.first.onset_date
  end

  def test_get_conditions_onset_date_nil_when_absent
    condition = build_condition_resource(onsetDateTime: nil)
    condition.delete("onsetPeriod")
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    assert_nil results.first.onset_date
  end

  def test_get_conditions_returns_nil_when_subject_reference_mismatches_patient
    condition = build_condition_resource(subject: { "reference" => "Patient/pt_other" })
    result = get_conditions_with_bundle(conditions_bundle([ condition ]), patient_id: "pt_001")

    assert_nil result
  end

  def test_get_conditions_returns_nil_when_onset_unparseable
    condition = build_condition_resource(onsetDateTime: "not-a-date")
    result = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_nil result
  end

  def test_get_conditions_returns_empty_array_for_successful_bundle_with_no_entries
    url_seen = nil
    bundle = conditions_bundle([])
    expected = "#{@adapter.base_url}/Condition?#{URI.encode_www_form(patient: "pt_001")}"

    results = @adapter.stub(:http_get, ->(url) { url_seen = url; consumed_http_response(bundle) }) do
      @adapter.get_conditions("pt_001")
    end

    assert_equal expected, url_seen
    assert_equal [], results
  end

  def test_get_conditions_returns_nil_on_non_success_http
    result = get_conditions_with_http_response(consumed_http_response("{}", status: 500))

    assert_nil result
  end

  def test_get_conditions_returns_nil_on_invalid_json
    result = get_conditions_with_http_response(consumed_http_response("not json"))

    assert_nil result
  end

  def test_get_conditions_returns_nil_when_response_is_not_a_bundle
    result = get_conditions_with_http_response(consumed_http_response({ "resourceType" => "Patient", "id" => "pt_001" }))

    assert_nil result
  end

  def test_get_conditions_returns_nil_when_bundle_contains_fatal_operation_outcome
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => { "resourceType" => "OperationOutcome", "issue" => [ { "severity" => "fatal", "code" => "processing" } ] } } ]
    }
    result = get_conditions_with_http_response(consumed_http_response(bundle))

    assert_nil result
  end

  def test_get_conditions_returns_nil_on_timeout
    result = get_conditions_with_http_error(Timeout::Error.new("timeout"))
    assert_nil result
  end

  def test_get_conditions_returns_nil_on_socket_error
    result = get_conditions_with_http_error(SocketError.new("socket"))
    assert_nil result
  end

  def test_get_medications_requests_medication_request_search_with_patient_query
    bundle = medications_bundle([])
    url_seen = nil
    expected = "#{@adapter.base_url}/MedicationRequest?#{URI.encode_www_form(patient: "pt_001")}"

    @adapter.stub(:http_get, ->(url) { url_seen = url; consumed_http_response(bundle) }) do
      @adapter.get_medications("pt_001")
    end

    assert_equal expected, url_seen
  end

  def test_get_medications_maps_codeable_concept_on_request
    request = build_medication_request_resource(
      medicationCodeableConcept: {
        "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M001", "display" => "TEST MEDICATION 001" } ]
      },
      status: "active",
      authoredOn: "2024-06-01",
      dosageInstruction: [ { "text" => "TEST DOSAGE 001" } ]
    )
    results = get_medications_with_bundle(medications_bundle([ request ]))

    assert_equal 1, results.size
    ref = results.first
    assert_instance_of Corvid::MedicationReference, ref
    assert_equal "M001", ref.code
    assert_equal "http://example.test/rxnorm", ref.code_system
    assert_equal "TEST MEDICATION 001", ref.display
    assert_equal "active", ref.status
    assert_equal Date.new(2024, 6, 1), ref.authored_on
    assert_equal "TEST DOSAGE 001", ref.dosage_text
  end

  def test_get_medications_resolves_contained_medication_reference
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "#med1" },
      contained: [
        {
          "resourceType" => "Medication",
          "id" => "med1",
          "code" => {
            "text" => "TEST MEDICATION 001",
            "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M001" } ]
          }
        }
      ]
    )
    results = get_medications_with_bundle(medications_bundle([ request ]))

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
    assert_equal "TEST MEDICATION 001", results.first.display
  end

  def test_get_medications_resolves_bundle_included_medication_reference
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "Medication/med_inc_001" }
    )
    included = {
      "resourceType" => "Medication",
      "id" => "med_inc_001",
      "code" => { "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M001", "display" => "TEST MEDICATION 001" } ] }
    }
    bundle = medications_bundle([ request ], includes: [ included ])
    results = get_medications_with_bundle(bundle)

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
    assert_equal "TEST MEDICATION 001", results.first.display
  end

  def test_get_medications_returns_nil_when_medication_reference_unresolvable
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "Medication/missing" }
    )
    result = get_medications_with_bundle(medications_bundle([ request ]))

    assert_nil result
  end

  def test_get_medications_returns_nil_when_subject_reference_mismatches_patient
    request = build_medication_request_resource(subject: { "reference" => "Patient/pt_other" })
    result = get_medications_with_bundle(medications_bundle([ request ]), patient_id: "pt_001")

    assert_nil result
  end

  def test_get_medications_returns_nil_when_authored_on_unparseable
    request = build_medication_request_resource(authoredOn: "not-a-date")
    result = get_medications_with_bundle(medications_bundle([ request ]))

    assert_nil result
  end

  def test_get_medications_returns_empty_array_for_successful_bundle_with_no_entries
    url_seen = nil
    bundle = medications_bundle([])
    expected = "#{@adapter.base_url}/MedicationRequest?#{URI.encode_www_form(patient: "pt_001")}"

    results = @adapter.stub(:http_get, ->(url) { url_seen = url; consumed_http_response(bundle) }) do
      @adapter.get_medications("pt_001")
    end

    assert_equal expected, url_seen
    assert_equal [], results
  end

  def test_get_medications_returns_nil_on_non_success_http
    result = get_medications_with_http_response(consumed_http_response("{}", status: 503))

    assert_nil result
  end

  private

  def consumed_http_response(body, status: 200)
    json_body = body.is_a?(String) ? body : JSON.generate(body)
    response_class = Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPOK
    response = response_class.new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, json_body)
    response.instance_variable_set(:@read, true)
    response
  end

  def conditions_bundle(conditions)
    {
      "resourceType" => "Bundle",
      "entry" => conditions.map { |c| { "resource" => c } }
    }
  end

  def medications_bundle(requests, includes: [])
    entries = requests.map { |r| { "resource" => r, "search" => { "mode" => "match" } } }
    includes.each do |inc|
      entries << { "resource" => inc, "search" => { "mode" => "include" } }
    end
    { "resourceType" => "Bundle", "entry" => entries }
  end

  def build_condition_resource(overrides = {})
    category_code = overrides.delete(:category_code) || "problem-list-item"
    clinical_status = overrides.delete(:clinical_status) || "active"
    {
      "resourceType" => "Condition",
      "id" => "cond_001",
      "subject" => { "reference" => "Patient/pt_001" },
      "category" => [ {
        "coding" => [ { "system" => CONDITION_CATEGORY_SYSTEM, "code" => category_code } ]
      } ],
      "clinicalStatus" => { "coding" => [ { "code" => clinical_status } ] },
      "code" => {
        "coding" => [ { "system" => "http://example.test/codes", "code" => "C001", "display" => "TEST CONDITION 001" } ]
      },
      "onsetDateTime" => "2020-01-01"
    }.deep_merge(overrides.deep_stringify_keys)
  end

  def build_medication_request_resource(overrides = {})
    base = {
      "resourceType" => "MedicationRequest",
      "id" => "mr_001",
      "status" => "active",
      "subject" => { "reference" => "Patient/pt_001" },
      "authoredOn" => "2024-06-01",
      "medicationCodeableConcept" => {
        "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M001", "display" => "TEST MEDICATION 001" } ]
      },
      "dosageInstruction" => [ { "text" => "TEST DOSAGE 001" } ]
    }
    merged = base.deep_merge(overrides.deep_stringify_keys)
    merged.delete("medicationCodeableConcept") if overrides.key?(:medicationCodeableConcept) && overrides[:medicationCodeableConcept].nil?
    merged
  end

  def get_conditions_with_bundle(bundle, patient_id: "pt_001")
    get_conditions_with_http_response(consumed_http_response(bundle), patient_id: patient_id)
  end

  def get_conditions_with_http_response(response, patient_id: "pt_001")
    @adapter.stub(:http_get, response) { @adapter.get_conditions(patient_id) }
  end

  def get_conditions_with_http_error(error)
    @adapter.stub(:http_get, ->(_url) { raise error }) { @adapter.get_conditions("pt_001") }
  end

  def get_medications_with_bundle(bundle, patient_id: "pt_001")
    get_medications_with_http_response(consumed_http_response(bundle), patient_id: patient_id)
  end

  def get_medications_with_http_response(response, patient_id: "pt_001")
    @adapter.stub(:http_get, response) { @adapter.get_medications(patient_id) }
  end

  def list_claim_with_provider(provider)
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Claim",
        "id" => "clm_pr_helper",
        "patient" => { "reference" => "Patient/pt_pr3" },
        "provider" => provider,
        "item" => [ {
          "sequence" => 1,
          "productOrService" => { "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ] },
          "net" => { "value" => 100.0, "currency" => "USD" }
        } ]
      } } ]
    }
    @adapter.stub(:fhir_search, bundle) { @adapter.list_claims("pt_pr3").first }
  end
end
