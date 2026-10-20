# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "zlib"
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

  def test_get_coverages_overrides_base_implementation
    owner = Corvid::Adapters::FhirAdapter.instance_method(:get_coverages).owner
    assert_equal Corvid::Adapters::FhirAdapter, owner
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

  # -- get_coverages (issue #607) ---------------------------------------------
  # Active-coverage date filtering uses Date.current in the adapter; stub both
  # Date.current and Date.today to FIXED_COVERAGE_TODAY for determinism.

  FIXED_COVERAGE_TODAY = Date.new(2026, 6, 15)

  def test_get_coverages_maps_only_active_coverages_on_single_page
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_active",
          for_patient: "pt_cov",
          status: "active",
          payer_display: "TEST PAYER 001",
          type_code: "MCDSC",
          subscriber_id: "POL_001",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31),
          plan_name: "TEST PLAN 001"
        ),
        coverage_fhir_resource(
          id: "cov_cancelled",
          for_patient: "pt_cov",
          status: "cancelled",
          payer_display: "TEST PAYER 002",
          type_code: "EHCPOL",
          subscriber_id: "POL_002",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        ),
        coverage_fhir_resource(
          id: "cov_expired",
          for_patient: "pt_cov",
          status: "active",
          payer_display: "TEST PAYER 003",
          type_code: "MCRSC",
          subscriber_id: "POL_003",
          period_start: Date.new(2024, 1, 1),
          period_end: Date.new(2025, 12, 31)
        ),
        coverage_fhir_resource(
          id: "cov_future",
          for_patient: "pt_cov",
          status: "active",
          payer_display: "TEST PAYER 004",
          type_code: "VET",
          subscriber_id: "POL_004",
          period_start: Date.new(2027, 1, 1),
          period_end: Date.new(2027, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_cov") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_cov")
      assert_equal [ {
        payer_name: "TEST PAYER 001",
        plan_name: "TEST PLAN 001",
        coverage_type: "MCDSC",
        policy_number: "POL_001",
        coverage_start: Date.new(2026, 1, 1),
        coverage_end: Date.new(2026, 12, 31),
        status: "active"
      } ], result
      assert_equal [ coverage_search_url("pt_cov") ], @requested_urls
    end
  end

  def test_get_coverages_follows_next_link_and_returns_both_pages_in_order
    page1_url = coverage_search_url("pt_pag")
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/pt_pag")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_page1",
          for_patient: "pt_pag",
          status: "active",
          payer_display: "TEST PAYER PAGE1",
          type_code: "MCDSC",
          subscriber_id: "POL_P1",
          period_start: Date.new(2026, 1, 1),
          plan_name: "TEST PLAN PAGE1"
        )
      ],
      next_url: page2_url
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_page2",
          for_patient: "pt_pag",
          status: "active",
          payer_display: "TEST PAYER PAGE2",
          type_code: "EHCPOL",
          subscriber_id: "POL_P2",
          period_start: Date.new(2026, 2, 1),
          plan_value: "TEST PLAN PAGE2 VALUE"
        )
      ]
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      result = @adapter.get_coverages("pt_pag")
      assert_equal 2, result.size
      assert_equal "TEST PAYER PAGE1", result[0][:payer_name]
      assert_equal "TEST PAYER PAGE2", result[1][:payer_name]
      assert_equal [ page1_url, page2_url ], @requested_urls
    end
  end

  def test_get_coverages_returns_nil_when_second_page_returns_503
    page1_url = coverage_search_url("pt_503")
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/pt_503")}"
    page1 = coverage_bundle(
      entries: [ coverage_fhir_resource(id: "cov_a", for_patient: "pt_503", status: "active",
                                        payer_display: "TEST PAYER 503",
                                        type_code: "MCDSC", subscriber_id: "POL_503") ],
      next_url: page2_url
    )
    with_stubbed_coverage_http({
      page1_url => http_ok_json(page1),
      page2_url => http_error_response(Net::HTTPServiceUnavailable, "503", "Unavailable")
    }) do
      assert_nil @adapter.get_coverages("pt_503")
    end
  end

  def test_get_coverages_returns_nil_when_first_page_returns_500
    page1_url = coverage_search_url("pt_500")
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/pt_500")}"
    with_stubbed_coverage_http({
      page1_url => http_error_response(Net::HTTPInternalServerError, "500", "Error"),
      page2_url => http_ok_json(coverage_bundle(entries: []))
    }) do
      assert_nil @adapter.get_coverages("pt_500")
      refute_includes @requested_urls, page2_url
    end
  end

  def test_get_coverages_returns_nil_on_invalid_json_body
    with_stubbed_coverage_http({ coverage_search_url("pt_bad_json") => http_ok_body("not-json{{{") }) do
      assert_nil @adapter.get_coverages("pt_bad_json")
    end
  end

  def test_get_coverages_returns_nil_when_json_is_not_a_bundle
    with_stubbed_coverage_http({
      coverage_search_url("pt_not_bundle") => http_ok_json({ "resourceType" => "Patient", "id" => "pt_not_bundle" })
    }) do
      assert_nil @adapter.get_coverages("pt_not_bundle")
    end
  end

  def test_get_coverages_returns_nil_when_next_link_is_off_origin_without_fetching_it
    evil_next = "https://evil.example.com/r4/Coverage?#{URI.encode_www_form(page: "2")}"
    page1_url = coverage_search_url("pt_off_origin")
    page1 = coverage_bundle(
      entries: [ coverage_fhir_resource(id: "cov_x", for_patient: "pt_off_origin", status: "active",
                                        payer_display: "TEST PAYER X",
                                        type_code: "MCDSC", subscriber_id: "POL_X") ],
      next_url: evil_next
    )
    off_origin_fetched = []
    with_stubbed_coverage_http({
      page1_url => http_ok_json(page1),
      evil_next => lambda {
        off_origin_fetched << true
        http_ok_json(coverage_bundle(entries: []))
      }
    }) do
      assert_nil @adapter.get_coverages("pt_off_origin")
      assert_equal [ page1_url ], @requested_urls
      assert_empty off_origin_fetched, "off-origin next must not be fetched"
    end
  end

  def test_get_coverages_returns_nil_when_next_link_loops_to_already_visited_url
    page1_url = coverage_search_url("pt_loop")
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/pt_loop")}"
    page1 = coverage_bundle(
      entries: [ coverage_fhir_resource(id: "cov_loop1", for_patient: "pt_loop", status: "active",
                                        payer_display: "TEST PAYER LOOP1",
                                        type_code: "MCDSC", subscriber_id: "POL_L1") ],
      next_url: page2_url
    )
    page2 = coverage_bundle(entries: [], next_url: page1_url)
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      assert_nil @adapter.get_coverages("pt_loop")
    end
  end

  def test_get_coverages_returns_empty_array_for_bundle_without_entry_key
    bundle = { "resourceType" => "Bundle" }
    with_stubbed_coverage_http({ coverage_search_url("pt_empty") => http_ok_json(bundle) }) do
      assert_equal [], @adapter.get_coverages("pt_empty")
      assert_equal [ coverage_search_url("pt_empty") ], @requested_urls
    end
  end

  def test_get_coverages_returns_nil_when_http_get_raises_timeout_error
    with_stubbed_coverage_http(lambda { |_url| raise Timeout::Error, "timed out" }) do
      assert_nil @adapter.get_coverages("pt_timeout")
    end
  end

  def test_get_coverages_plan_name_from_plan_class_name
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_plan_name",
          for_patient: "pt_plan_name",
          status: "active",
          payer_display: "TEST PAYER PLAN",
          type_code: "MCDSC",
          subscriber_id: "POL_PN",
          plan_name: "TEST PLAN FROM NAME"
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_plan_name") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_plan_name")
      assert_equal 1, result.size
      assert_equal "TEST PLAN FROM NAME", result.first[:plan_name]
    end
  end

  def test_get_coverages_plan_name_from_plan_class_value_when_name_absent
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_plan_value",
          for_patient: "pt_plan_value",
          status: "active",
          payer_display: "TEST PAYER VALUE",
          type_code: "MCDSC",
          subscriber_id: "POL_PV",
          plan_value: "TEST PLAN FROM VALUE"
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_plan_value") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_plan_value")
      assert_equal 1, result.size
      assert_equal "TEST PLAN FROM VALUE", result.first[:plan_name]
    end
  end

  def test_get_coverages_plan_name_nil_when_no_plan_class
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_no_plan",
          for_patient: "pt_no_plan",
          status: "active",
          payer_display: "TEST PAYER NO PLAN",
          type_code: "MCDSC",
          subscriber_id: "POL_NP"
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_no_plan") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_no_plan")
      assert_equal 1, result.size
      assert_nil result.first[:plan_name]
    end
  end

  # N1 — beneficiary must match queried patient (server filter sanity check)

  def test_get_coverages_returns_nil_when_active_coverage_beneficiary_is_wrong_patient
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_wrong_pt",
          beneficiary_reference: "Patient/pt_other",
          status: "active",
          payer_display: "TEST PAYER WRONG",
          type_code: "MCDSC",
          subscriber_id: "POL_WRONG",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_001") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_001")
    end
  end

  def test_get_coverages_accepts_beneficiary_relative_reference_for_queried_patient
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_rel_ben",
          beneficiary_reference: "Patient/pt_001",
          status: "active",
          payer_display: "TEST PAYER REL",
          type_code: "MCDSC",
          subscriber_id: "POL_REL",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_001") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_001")
      assert_equal 1, result.size
      assert_equal "TEST PAYER REL", result.first[:payer_name]
    end
  end

  def test_get_coverages_accepts_beneficiary_absolute_reference_for_queried_patient
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_abs_ben",
          beneficiary_reference: "https://fhir.example.com/r4/Patient/pt_001",
          status: "active",
          payer_display: "TEST PAYER ABS",
          type_code: "MCDSC",
          subscriber_id: "POL_ABS",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_001") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_001")
      assert_equal 1, result.size
      assert_equal "TEST PAYER ABS", result.first[:payer_name]
    end
  end

  def test_get_coverages_returns_nil_when_active_coverage_has_no_beneficiary
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_no_ben",
          status: "active",
          payer_display: "TEST PAYER NO BEN",
          type_code: "MCDSC",
          subscriber_id: "POL_NB",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_001") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_001")
    end
  end

  # N2 — partial-precision FHIR date period bounds

  def test_get_coverages_includes_year_precision_period_on_fixed_today
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_year_prec",
          for_patient: "pt_year",
          status: "active",
          payer_display: "TEST PAYER YEAR",
          type_code: "MCDSC",
          subscriber_id: "POL_YR",
          period: { "start" => "2025", "end" => "2026" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_year") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_year")
      assert_equal 1, result.size, "year precision: start Jan 1 / end Dec 31 should include 2026-06-15"
    end
  end

  def test_get_coverages_includes_month_precision_period_on_fixed_today
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_month_prec",
          for_patient: "pt_month",
          status: "active",
          payer_display: "TEST PAYER MONTH",
          type_code: "MCDSC",
          subscriber_id: "POL_MO",
          period: { "start" => "2026-01", "end" => "2026-06" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_month") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_month")
      assert_equal 1, result.size, "month precision: end is last day of June 2026"
    end
  end

  def test_get_coverages_excludes_month_precision_period_ended_before_today
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_may_end",
          for_patient: "pt_may_end",
          status: "active",
          payer_display: "TEST PAYER MAY",
          type_code: "MCDSC",
          subscriber_id: "POL_ME",
          period: { "start" => "2026-01", "end" => "2026-05" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_may_end") => http_ok_json(bundle) }) do
      assert_equal [], @adapter.get_coverages("pt_may_end")
    end
  end

  def test_get_coverages_returns_nil_when_period_bound_is_unparseable
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_bad_date",
          for_patient: "pt_bad_date",
          status: "active",
          payer_display: "TEST PAYER BAD DATE",
          type_code: "MCDSC",
          subscriber_id: "POL_BD",
          period: { "start" => "2026-01-01", "end" => "not-a-date" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_bad_date") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_bad_date")
    end
  end

  # N3 — dateTime period bounds compare as instants against Time.current
  # Time.current and Date.current are pinned via with_stubbed_coverage_http(now: FIXED_COVERAGE_NOW).

  FIXED_COVERAGE_NOW = Time.utc(2026, 6, 15, 12, 0, 0)

  def test_get_coverages_includes_datetime_start_before_pinned_now_same_utc_day
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_dt_start_early",
          for_patient: "pt_dt1",
          status: "active",
          payer_display: "TEST PAYER DT1",
          type_code: "MCDSC",
          subscriber_id: "POL_DT1",
          period: { "start" => "2026-06-15T23:00:00+14:00" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_dt1") => http_ok_json(bundle) }, now: FIXED_COVERAGE_NOW) do
      result = @adapter.get_coverages("pt_dt1")
      assert_equal 1, result.size, "09:00Z start should be on or before 12:00Z now"
    end
  end

  def test_get_coverages_includes_datetime_start_later_same_utc_calendar_day
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_dt_start_later",
          for_patient: "pt_dt2",
          status: "active",
          payer_display: "TEST PAYER DT2",
          type_code: "MCDSC",
          subscriber_id: "POL_DT2",
          period: { "start" => "2026-06-16T01:00:00+14:00" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_dt2") => http_ok_json(bundle) }, now: FIXED_COVERAGE_NOW) do
      result = @adapter.get_coverages("pt_dt2")
      assert_equal 1, result.size, "11:00Z start is still on 2026-06-15 UTC calendar day vs date-only rules"
    end
  end

  def test_get_coverages_excludes_datetime_start_after_pinned_now
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_dt_start_after",
          for_patient: "pt_dt3",
          status: "active",
          payer_display: "TEST PAYER DT3",
          type_code: "MCDSC",
          subscriber_id: "POL_DT3",
          period: { "start" => "2026-06-15T13:00:00Z" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_dt3") => http_ok_json(bundle) }, now: FIXED_COVERAGE_NOW) do
      assert_equal [], @adapter.get_coverages("pt_dt3")
    end
  end

  def test_get_coverages_excludes_datetime_end_before_pinned_now
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_dt_end_before",
          for_patient: "pt_dt4",
          status: "active",
          payer_display: "TEST PAYER DT4",
          type_code: "MCDSC",
          subscriber_id: "POL_DT4",
          period: { "end" => "2026-06-15T11:00:00Z" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_dt4") => http_ok_json(bundle) }, now: FIXED_COVERAGE_NOW) do
      assert_equal [], @adapter.get_coverages("pt_dt4")
    end
  end

  # N4 — additional transport / protocol errors => nil

  def test_get_coverages_returns_nil_when_http_get_raises_bad_response
    with_stubbed_coverage_http(lambda { |_url| raise Net::HTTPBadResponse, "bad response" }) do
      assert_nil @adapter.get_coverages("pt_bad_resp")
    end
  end

  def test_get_coverages_returns_nil_when_http_get_raises_header_syntax_error
    with_stubbed_coverage_http(lambda { |_url| raise Net::HTTPHeaderSyntaxError, "bad header" }) do
      assert_nil @adapter.get_coverages("pt_bad_hdr")
    end
  end

  def test_get_coverages_returns_nil_when_http_get_raises_zlib_data_error
    with_stubbed_coverage_http(lambda { |_url| raise Zlib::DataError, "bad zlib" }) do
      assert_nil @adapter.get_coverages("pt_zlib")
    end
  end

  def test_get_coverages_returns_nil_when_http_get_raises_eof_error
    with_stubbed_coverage_http(lambda { |_url| raise EOFError, "eof" }) do
      assert_nil @adapter.get_coverages("pt_eof")
    end
  end

  # N5 — Bundle.total without entry

  def test_get_coverages_returns_nil_when_total_positive_but_entry_absent
    bundle = { "resourceType" => "Bundle", "total" => 3 }
    with_stubbed_coverage_http({ coverage_search_url("pt_total_pos") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_total_pos")
    end
  end

  def test_get_coverages_returns_empty_array_when_total_zero_and_entry_absent
    bundle = { "resourceType" => "Bundle", "total" => 0 }
    with_stubbed_coverage_http({ coverage_search_url("pt_total_zero") => http_ok_json(bundle) }) do
      assert_equal [], @adapter.get_coverages("pt_total_zero")
    end
  end

  # N6 — relative next link resolved against base_url

  def test_get_coverages_follows_relative_next_link_under_base_path
    page1_url = coverage_search_url("pt_001")
    relative_next = "/r4/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/pt_001")}"
    absolute_page2 = "https://fhir.example.com#{relative_next}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_p1",
          for_patient: "pt_001",
          status: "active",
          payer_display: "TEST PAYER P1",
          type_code: "MCDSC",
          subscriber_id: "POL_P1",
          period_start: Date.new(2026, 1, 1)
        )
      ],
      next_url: relative_next
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_p2",
          for_patient: "pt_001",
          status: "active",
          payer_display: "TEST PAYER P2",
          type_code: "EHCPOL",
          subscriber_id: "POL_P2",
          period_start: Date.new(2026, 2, 1)
        )
      ]
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), absolute_page2 => http_ok_json(page2) }) do
      result = @adapter.get_coverages("pt_001")
      refute_nil result, "relative next under /r4 must resolve and return both pages"
      assert_equal 2, result.size
      assert_equal [ page1_url, absolute_page2 ], @requested_urls
    end
  end

  def test_get_coverages_returns_nil_for_relative_next_outside_base_path_without_fetching
    page1_url = coverage_search_url("pt_rel_bad")
    relative_evil = "/other/Coverage?page=2"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_rel",
          for_patient: "pt_rel_bad",
          status: "active",
          payer_display: "TEST PAYER REL BAD",
          type_code: "MCDSC",
          subscriber_id: "POL_RB",
          period_start: Date.new(2026, 1, 1)
        )
      ],
      next_url: relative_evil
    )
    evil_absolute = "https://fhir.example.com#{relative_evil}"
    off_path_fetched = []
    with_stubbed_coverage_http({
      page1_url => http_ok_json(page1),
      evil_absolute => lambda {
        off_path_fetched << true
        http_ok_json(coverage_bundle(entries: []))
      }
    }) do
      assert_nil @adapter.get_coverages("pt_rel_bad")
      assert_equal [ page1_url ], @requested_urls
      assert_empty off_path_fetched
    end
  end

  # N7 — relation "Next" (any case) follows pagination like "next"

  # R1 (round 2) — self-pay is not insurance; definitive empty when only non-insurable

  def test_get_coverages_excludes_active_coverage_with_self_pay_type_code_pay
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_insured",
          for_patient: "pt_r1_pay",
          status: "active",
          payer_display: "TEST PAYER INSURED",
          type_code: "MCDSC",
          subscriber_id: "POL_INS",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        ),
        coverage_fhir_resource(
          id: "cov_self_pay_type",
          for_patient: "pt_r1_pay",
          status: "active",
          payer_display: "SELF PAY",
          type_code: "pay",
          subscriber_id: "SELF",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r1_pay") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_r1_pay")
      assert_equal 1, result.size
      assert_equal "MCDSC", result.first[:coverage_type]
    end
  end

  def test_get_coverages_excludes_active_coverage_when_payor_is_patient_reference
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_pt_payor",
          for_patient: "pt_r1_pt_payor",
          status: "active",
          payer_display: "PATIENT SELF",
          type_code: "EHCPOL",
          subscriber_id: "POL_PT",
          payor_reference: "Patient/pt_001",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r1_pt_payor") => http_ok_json(bundle) }) do
      assert_equal [], @adapter.get_coverages("pt_r1_pt_payor")
    end
  end

  def test_get_coverages_excludes_active_coverage_when_payor_is_related_person
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_rp_payor",
          for_patient: "pt_r1_rp",
          status: "active",
          payer_display: "GUARANTOR",
          type_code: "EHCPOL",
          subscriber_id: "POL_RP",
          payor_reference: "RelatedPerson/rp_001",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r1_rp") => http_ok_json(bundle) }) do
      assert_equal [], @adapter.get_coverages("pt_r1_rp")
    end
  end

  def test_get_coverages_returns_empty_array_when_bundle_contains_only_self_pay_coverages
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_only_pay",
          for_patient: "pt_r1_only",
          status: "active",
          payer_display: "SELF",
          type_code: "pay",
          subscriber_id: "ONLY_PAY",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r1_only") => http_ok_json(bundle) }) do
      assert_equal [], @adapter.get_coverages("pt_r1_only")
    end
  end

  # R2 — foreign-server absolute beneficiary must not match via suffix alone

  def test_get_coverages_returns_nil_when_beneficiary_absolute_reference_is_foreign_server
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_foreign_ben",
          beneficiary_reference: "https://other-ehr.example/fhir/Patient/pt_001",
          status: "active",
          payer_display: "TEST PAYER FOREIGN BEN",
          type_code: "MCDSC",
          subscriber_id: "POL_FB",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_001") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_001")
    end
  end

  # R3 — strict FHIR date grammar on present period bounds

  STRICT_INVALID_COVERAGE_PERIOD_BOUNDS = [
    "31",
    "Dec 2026",
    "Dec 31",
    "2026-1-5",
    "20270101",
    "2027/01/01",
    "2026-11-01Z",
    "2026-W43"
  ].freeze

  def test_get_coverages_returns_nil_for_strict_invalid_period_start_bounds
    STRICT_INVALID_COVERAGE_PERIOD_BOUNDS.each do |bad_start|
      bundle = coverage_bundle(
        entries: [
          coverage_fhir_resource(
            id: "cov_bad_start",
            for_patient: "pt_r3_start",
            status: "active",
            payer_display: "TEST PAYER R3",
            type_code: "MCDSC",
            subscriber_id: "POL_R3",
            period: { "start" => bad_start, "end" => "2026-12-31" }
          )
        ]
      )
      with_stubbed_coverage_http({ coverage_search_url("pt_r3_start") => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages("pt_r3_start"), "expected nil for invalid start #{bad_start.inspect}"
      end
    end
  end

  def test_get_coverages_returns_nil_for_strict_invalid_period_end_bounds
    STRICT_INVALID_COVERAGE_PERIOD_BOUNDS.each do |bad_end|
      bundle = coverage_bundle(
        entries: [
          coverage_fhir_resource(
            id: "cov_bad_end",
            for_patient: "pt_r3_end",
            status: "active",
            payer_display: "TEST PAYER R3",
            type_code: "MCDSC",
            subscriber_id: "POL_R3",
            period: { "start" => "2026-01-01", "end" => bad_end }
          )
        ]
      )
      with_stubbed_coverage_http({ coverage_search_url("pt_r3_end") => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages("pt_r3_end"), "expected nil for invalid end #{bad_end.inspect}"
      end
    end
  end

  # R4 — Bundle.total vs Coverage resource count; fatal bundle entries; malformed rows

  def test_get_coverages_returns_nil_when_total_three_but_only_one_coverage_resource_and_no_next
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_total_short",
          for_patient: "pt_r4_short",
          status: "active",
          payer_display: "TEST PAYER SHORT",
          type_code: "MCDSC",
          subscriber_id: "POL_SHORT",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 3
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r4_short") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_r4_short")
    end
  end

  def test_get_coverages_returns_list_when_total_two_across_two_pages_with_one_coverage_each
    page1_url = coverage_search_url("pt_r4_two")
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/pt_r4_two")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r4_p1",
          for_patient: "pt_r4_two",
          status: "active",
          payer_display: "TEST PAYER R4 P1",
          type_code: "MCDSC",
          subscriber_id: "POL_R4_1",
          period_start: Date.new(2026, 1, 1)
        )
      ],
      next_url: page2_url,
      total: 2
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r4_p2",
          for_patient: "pt_r4_two",
          status: "active",
          payer_display: "TEST PAYER R4 P2",
          type_code: "EHCPOL",
          subscriber_id: "POL_R4_2",
          period_start: Date.new(2026, 2, 1)
        )
      ]
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      result = @adapter.get_coverages("pt_r4_two")
      assert_equal 2, result.size
    end
  end

  def test_get_coverages_counts_inactive_coverages_toward_total_before_active_filter
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_active_count",
          for_patient: "pt_r4_count",
          status: "active",
          payer_display: "TEST PAYER COUNT",
          type_code: "MCDSC",
          subscriber_id: "POL_CNT",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        ),
        coverage_fhir_resource(
          id: "cov_cancelled_count",
          for_patient: "pt_r4_count",
          status: "cancelled",
          payer_display: "TEST PAYER CANCELLED",
          type_code: "EHCPOL",
          subscriber_id: "POL_CAN",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 3
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r4_count") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_r4_count")
    end
  end

  def test_get_coverages_skips_total_check_when_total_absent
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_no_total",
          for_patient: "pt_r4_no_total",
          status: "active",
          payer_display: "TEST PAYER NO TOTAL",
          type_code: "MCDSC",
          subscriber_id: "POL_NT",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r4_no_total") => http_ok_json(bundle) }) do
      assert_equal 1, @adapter.get_coverages("pt_r4_no_total").size
    end
  end

  def test_get_coverages_returns_nil_when_bundle_entry_is_operation_outcome_with_error_severity
    bundle = coverage_bundle(
      entries: [
        {
          "resource" => {
            "resourceType" => "OperationOutcome",
            "issue" => [ { "severity" => "error", "code" => "processing", "diagnostics" => "TEST" } ]
          }
        }
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r4_oo_err") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_r4_oo_err")
    end
  end

  def test_get_coverages_returns_nil_when_bundle_entry_is_operation_outcome_with_fatal_severity
    bundle = coverage_bundle(
      entries: [
        {
          "resource" => {
            "resourceType" => "OperationOutcome",
            "issue" => [ { "severity" => "fatal", "code" => "exception", "diagnostics" => "TEST" } ]
          }
        }
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r4_oo_fatal") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_r4_oo_fatal")
    end
  end

  def test_get_coverages_returns_coverage_when_operation_outcome_issue_is_warning_only
    bundle = coverage_bundle(
      entries: [
        {
          "resource" => {
            "resourceType" => "OperationOutcome",
            "issue" => [ { "severity" => "warning", "code" => "informational", "diagnostics" => "TEST" } ]
          }
        },
        coverage_fhir_resource(
          id: "cov_after_warn",
          for_patient: "pt_r4_warn",
          status: "active",
          payer_display: "TEST PAYER WARN",
          type_code: "MCDSC",
          subscriber_id: "POL_WARN",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r4_warn") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_r4_warn")
      assert_equal 1, result.size
      assert_equal "TEST PAYER WARN", result.first[:payer_name]
    end
  end

  def test_get_coverages_returns_nil_when_coverage_period_is_present_but_not_an_object
    resource = coverage_fhir_resource(
      id: "cov_bad_period",
      for_patient: "pt_r4_period",
      status: "active",
      payer_display: "TEST PAYER BAD PERIOD",
      type_code: "MCDSC",
      subscriber_id: "POL_BP",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    resource["period"] = "not-a-period"
    bundle = coverage_bundle(entries: [ resource ])
    with_stubbed_coverage_http({ coverage_search_url("pt_r4_period") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_r4_period")
    end
  end

  def test_get_coverages_returns_nil_when_active_coverage_has_no_status
    resource = coverage_fhir_resource(
      id: "cov_no_status",
      for_patient: "pt_r4_status",
      payer_display: "TEST PAYER NO STATUS",
      type_code: "MCDSC",
      subscriber_id: "POL_NS",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    resource.delete("status")
    bundle = coverage_bundle(entries: [ resource ])
    with_stubbed_coverage_http({ coverage_search_url("pt_r4_status") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_r4_status")
    end
  end

  # R5 — relative next links resolve against the page URL (RFC 3986), not base_url alone

  def test_get_coverages_follows_query_only_relative_next_resolved_against_page_url
    page1_url = coverage_search_url("pt_r5_query")
    relative_next = "?page=2"
    page2_url = "https://fhir.example.com/r4/Coverage?page=2"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r5_q1",
          for_patient: "pt_r5_query",
          status: "active",
          payer_display: "TEST PAYER R5 Q1",
          type_code: "MCDSC",
          subscriber_id: "POL_R5Q1",
          period_start: Date.new(2026, 1, 1)
        )
      ],
      next_url: relative_next
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r5_q2",
          for_patient: "pt_r5_query",
          status: "active",
          payer_display: "TEST PAYER R5 Q2",
          type_code: "EHCPOL",
          subscriber_id: "POL_R5Q2",
          period_start: Date.new(2026, 2, 1)
        )
      ]
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      result = @adapter.get_coverages("pt_r5_query")
      refute_nil result
      assert_equal 2, result.size
      assert_equal [ page1_url, page2_url ], @requested_urls
    end
  end

  def test_get_coverages_follows_resource_relative_next_resolved_against_page_url
    page1_url = coverage_search_url("pt_r5_res")
    relative_next = "Coverage?page=2"
    page2_url = "https://fhir.example.com/r4/Coverage?page=2"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r5_r1",
          for_patient: "pt_r5_res",
          status: "active",
          payer_display: "TEST PAYER R5 R1",
          type_code: "MCDSC",
          subscriber_id: "POL_R5R1",
          period_start: Date.new(2026, 1, 1)
        )
      ],
      next_url: relative_next
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r5_r2",
          for_patient: "pt_r5_res",
          status: "active",
          payer_display: "TEST PAYER R5 R2",
          type_code: "EHCPOL",
          subscriber_id: "POL_R5R2",
          period_start: Date.new(2026, 2, 1)
        )
      ]
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      result = @adapter.get_coverages("pt_r5_res")
      refute_nil result
      assert_equal 2, result.size
      assert_equal [ page1_url, page2_url ], @requested_urls
    end
  end

  # R6 — returned coverage_start/coverage_end reflect FHIR precision in mapped attributes

  def test_get_coverages_maps_partial_precision_period_bounds_to_calendar_dates
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r6_prec",
          for_patient: "pt_r6_prec",
          status: "active",
          payer_display: "TEST PAYER R6",
          type_code: "MCDSC",
          subscriber_id: "POL_R6",
          period: { "start" => "2026", "end" => "2026-12" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r6_prec") => http_ok_json(bundle) }) do
      row = @adapter.get_coverages("pt_r6_prec").first
      assert_equal Date.new(2026, 1, 1), row[:coverage_start]
      assert_equal Date.new(2026, 12, 31), row[:coverage_end]
    end
  end

  def test_get_coverages_maps_year_only_end_bound_to_december_31_in_attributes
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r6_year_end",
          for_patient: "pt_r6_ye",
          status: "active",
          payer_display: "TEST PAYER R6 YE",
          type_code: "MCDSC",
          subscriber_id: "POL_R6YE",
          period: { "start" => "2026-01-01", "end" => "2026" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r6_ye") => http_ok_json(bundle) }) do
      row = @adapter.get_coverages("pt_r6_ye").first
      assert_equal Date.new(2026, 12, 31), row[:coverage_end]
    end
  end

  def test_get_coverages_maps_datetime_period_bound_to_utc_calendar_date_in_attributes
    # dateTime instants map to the UTC calendar date of that instant (not Time.zone).
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_r6_dt",
          for_patient: "pt_r6_dt",
          status: "active",
          payer_display: "TEST PAYER R6 DT",
          type_code: "MCDSC",
          subscriber_id: "POL_R6DT",
          period: { "start" => "2026-06-15T23:30:00+14:00", "end" => "2026-12-31" }
        )
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_r6_dt") => http_ok_json(bundle) }, now: FIXED_COVERAGE_NOW) do
      row = @adapter.get_coverages("pt_r6_dt").first
      assert_equal Date.new(2026, 6, 15), row[:coverage_start]
    end
  end

  # S1 (round 3) — insurance allowlist: Organization payors only, no self-pay codings, kind insurance

  PHDSC_SOP_SYSTEM = "urn:oid:2.16.840.1.113883.3.221.5"
  PHDSC_SOP_SYSTEM_BARE_OID = "2.16.840.1.113883.3.221.5"
  COVERAGE_SELFPAY_SYSTEM = "http://terminology.hl7.org/CodeSystem/coverage-selfpay"
  FHIR_STU3_COVERAGE_SELFPAY_SYSTEM = "http://hl7.org/fhir/coverage-selfpay"
  X12_CLAIM_FILING_INDICATOR_SYSTEM = "https://x12.org/codes/claim-filing-indicator-codes"

  ISSUE_607_SOP_INCLUDED_ON_URN = %w[2 21 5 511 1].freeze
  ISSUE_607_SOP_EXCLUDED_ON_URN = %w[33 331 3 8 82 89 9 95].freeze

  def test_get_coverages_returns_empty_when_only_coverage_is_phscd_sop_81_with_organization_payor
    resource = coverage_fhir_resource(
      id: "cov_s1_sop81",
      for_patient: "pt_s1_sop81",
      status: "active",
      payer_display: "TEST PAYER SOP81",
      type_codings: [ { "system" => PHDSC_SOP_SYSTEM, "code" => "81" } ],
      subscriber_id: "POL_SOP81",
      payor_reference: "Organization/org_sop81",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    assert_single_excluded_coverage_returns_empty("pt_s1_sop81", resource)
  end

  def test_get_coverages_returns_empty_when_type_coding_includes_self_pay_pay_in_any_position
    resource = coverage_fhir_resource(
      id: "cov_s1_dual_coding",
      for_patient: "pt_s1_dual",
      status: "active",
      payer_display: "TEST PAYER DUAL",
      type_codings: [
        { "system" => "http://local.test/coverage", "code" => "SP" },
        { "system" => COVERAGE_SELFPAY_SYSTEM, "code" => "pay" }
      ],
      subscriber_id: "POL_DUAL",
      payor_reference: "Organization/org_dual",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    assert_single_excluded_coverage_returns_empty("pt_s1_dual", resource)
  end

  def test_get_coverages_returns_empty_when_payor_is_absolute_patient_reference
    resource = coverage_fhir_resource(
      id: "cov_s1_abs_pt",
      for_patient: "pt_s1_abs_pt",
      status: "active",
      payer_display: "TEST PATIENT ABS",
      type_code: "EHCPOL",
      subscriber_id: "POL_ABS_PT",
      payor_reference: "#{@adapter.base_url}/Patient/pt_001",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    assert_single_excluded_coverage_returns_empty("pt_s1_abs_pt", resource)
  end

  def test_get_coverages_returns_empty_when_payor_is_logical_patient_without_organization_reference
    resource = coverage_fhir_resource(
      id: "cov_s1_logical_pt",
      for_patient: "pt_s1_logical",
      status: "active",
      payer_display: "TEST LOGICAL PT",
      type_code: "EHCPOL",
      subscriber_id: "POL_LOGICAL",
      payors: [
        {
          "type" => "Patient",
          "identifier" => { "system" => "http://test.local/patient", "value" => "pt_001" }
        }
      ],
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    assert_single_excluded_coverage_returns_empty("pt_s1_logical", resource)
  end

  def test_get_coverages_returns_empty_when_payor_is_display_only_without_organization_reference
    resource = coverage_fhir_resource(
      id: "cov_s1_display",
      for_patient: "pt_s1_display",
      status: "active",
      payer_display: "TEST SELF PAY",
      type_code: "EHCPOL",
      subscriber_id: "POL_DISPLAY",
      payors: [ { "display" => "TEST SELF PAY" } ],
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    assert_single_excluded_coverage_returns_empty("pt_s1_display", resource)
  end

  def test_get_coverages_returns_empty_when_coverage_kind_is_self_pay_with_payment_by_and_no_payor
    resource = coverage_fhir_resource(
      id: "cov_s1_r5_kind",
      for_patient: "pt_s1_r5_kind",
      status: "active",
      payer_display: "UNUSED",
      type_code: "EHCPOL",
      subscriber_id: "POL_R5K",
      skip_payor: true,
      kind: "self-pay",
      payment_by: [ { "party" => { "reference" => "Patient/pt_001" }, "amount" => { "value" => 0, "currency" => "USD" } } ],
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    assert_single_excluded_coverage_returns_empty("pt_s1_r5_kind", resource)
  end

  def test_get_coverages_returns_empty_when_payor_is_related_person_reference
    resource = coverage_fhir_resource(
      id: "cov_s1_rp",
      for_patient: "pt_s1_rp",
      status: "active",
      payer_display: "GUARANTOR",
      type_code: "EHCPOL",
      subscriber_id: "POL_RP",
      payor_reference: "RelatedPerson/rp_1",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    assert_single_excluded_coverage_returns_empty("pt_s1_rp", resource)
  end

  def test_get_coverages_returns_empty_when_one_payor_is_organization_and_second_is_patient
    resource = coverage_fhir_resource(
      id: "cov_s1_mixed_payor",
      for_patient: "pt_s1_mixed",
      status: "active",
      payer_display: "TEST MIXED",
      type_code: "EHCPOL",
      subscriber_id: "POL_MIXED",
      payors: [
        { "reference" => "Organization/org_1", "display" => "TEST ORG" },
        { "reference" => "Patient/pt_001", "display" => "TEST PATIENT" }
      ],
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    assert_single_excluded_coverage_returns_empty("pt_s1_mixed", resource)
  end

  def test_get_coverages_includes_active_coverage_with_organization_payor_and_ehcpol_type
    bundle = coverage_bundle_total_one(
      coverage_fhir_resource(
        id: "cov_s1_pos_rel",
        for_patient: "pt_s1_pos_rel",
        status: "active",
        payer_display: "TEST PAYER POS REL",
        type_code: "EHCPOL",
        subscriber_id: "POL_POS_REL",
        payor_reference: "Organization/org_1",
        period_start: Date.new(2026, 1, 1),
        period_end: Date.new(2026, 12, 31)
      )
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_s1_pos_rel") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_s1_pos_rel")
      assert_equal 1, result.size
      assert_equal "EHCPOL", result.first[:coverage_type]
      assert_equal "TEST PAYER POS REL", result.first[:payer_name]
    end
  end

  def test_get_coverages_includes_active_coverage_with_absolute_organization_payor_reference
    bundle = coverage_bundle_total_one(
      coverage_fhir_resource(
        id: "cov_s1_pos_abs",
        for_patient: "pt_s1_pos_abs",
        status: "active",
        payer_display: "TEST PAYER POS ABS",
        type_code: "EHCPOL",
        subscriber_id: "POL_POS_ABS",
        payor_reference: "#{@adapter.base_url}/Organization/org_1",
        period_start: Date.new(2026, 1, 1),
        period_end: Date.new(2026, 12, 31)
      )
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_s1_pos_abs") => http_ok_json(bundle) }) do
      result = @adapter.get_coverages("pt_s1_pos_abs")
      assert_equal 1, result.size
      assert_equal "TEST PAYER POS ABS", result.first[:payer_name]
    end
  end

  # D1 — PHDSC Source of Payment Typology insurer families (issue #607)

  def test_get_coverages_includes_active_coverage_for_phscd_sop_insurer_family_on_urn_system
    ISSUE_607_SOP_INCLUDED_ON_URN.each do |sop_code|
      patient_id = "pt_d1_inc_#{sop_code}"
      resource = issue_607_organization_coverage(
        id: "cov_d1_inc_#{sop_code}",
        for_patient: patient_id,
        type_codings: [ { "system" => PHDSC_SOP_SYSTEM, "code" => sop_code } ]
      )
      assert_single_included_issue_607_coverage(patient_id, resource,
                                                "PHDSC SOP #{sop_code.inspect} on urn system")
    end
  end

  def test_get_coverages_excludes_active_coverage_for_phscd_sop_non_insurer_family_on_urn_system
    ISSUE_607_SOP_EXCLUDED_ON_URN.each do |sop_code|
      patient_id = "pt_d1_exc_#{sop_code}"
      resource = issue_607_organization_coverage(
        id: "cov_d1_exc_#{sop_code}",
        for_patient: patient_id,
        type_codings: [ { "system" => PHDSC_SOP_SYSTEM, "code" => sop_code } ]
      )
      assert_single_excluded_issue_607_coverage(patient_id, resource,
                                                "PHDSC SOP #{sop_code.inspect} on urn system")
    end
  end

  def test_get_coverages_includes_active_coverage_for_phscd_sop_insurer_family_on_bare_oid_system
    resource = issue_607_organization_coverage(
      id: "cov_d1_bare_inc",
      for_patient: "pt_d1_bare_inc",
      type_codings: [ { "system" => PHDSC_SOP_SYSTEM_BARE_OID, "code" => "21" } ]
    )
    assert_single_included_issue_607_coverage("pt_d1_bare_inc", resource,
                                              "PHDSC SOP 21 on bare OID system")
  end

  def test_get_coverages_excludes_active_coverage_for_phscd_sop_non_insurer_on_bare_oid_system
    resource = issue_607_organization_coverage(
      id: "cov_d1_bare_exc",
      for_patient: "pt_d1_bare_exc",
      type_codings: [ { "system" => PHDSC_SOP_SYSTEM_BARE_OID, "code" => "82" } ]
    )
    assert_single_excluded_issue_607_coverage("pt_d1_bare_exc", resource,
                                              "PHDSC SOP 82 on bare OID system")
  end

  def test_get_coverages_excludes_active_coverage_when_sop_non_insurer_coding_alongside_ehcpol
    resource = issue_607_organization_coverage(
      id: "cov_d1_mixed",
      for_patient: "pt_d1_mixed",
      type_codings: [
        { "system" => PHDSC_SOP_SYSTEM, "code" => "82" },
        { "code" => "EHCPOL" }
      ]
    )
    assert_single_excluded_issue_607_coverage("pt_d1_mixed", resource,
                                                "SOP 82 with EHCPOL must exclude")
  end

  # D2 — additional self-pay signals (issue #607)

  def test_get_coverages_excludes_active_coverage_with_stu3_self_pay_coding_pay
    resource = issue_607_organization_coverage(
      id: "cov_d2_stu3_pay",
      for_patient: "pt_d2_stu3_pay",
      type_codings: [ { "system" => FHIR_STU3_COVERAGE_SELFPAY_SYSTEM, "code" => "pay" } ]
    )
    assert_single_excluded_issue_607_coverage("pt_d2_stu3_pay", resource, "STU3 coverage-selfpay pay")
  end

  def test_get_coverages_excludes_active_coverage_with_x12_claim_filing_indicator_09_with_system
    resource = issue_607_organization_coverage(
      id: "cov_d2_x12_sys",
      for_patient: "pt_d2_x12_sys",
      type_codings: [ { "system" => X12_CLAIM_FILING_INDICATOR_SYSTEM, "code" => "09" } ]
    )
    assert_single_excluded_issue_607_coverage("pt_d2_x12_sys", resource, "X12 09 with system")
  end

  def test_get_coverages_excludes_active_coverage_with_x12_claim_filing_indicator_09_without_system
    resource = issue_607_organization_coverage(
      id: "cov_d2_x12_nosys",
      for_patient: "pt_d2_x12_nosys",
      type_codings: [ { "code" => "09" } ]
    )
    assert_single_excluded_issue_607_coverage("pt_d2_x12_nosys", resource, "X12 09 without system")
  end

  def test_get_coverages_excludes_active_coverage_when_type_text_is_self_pay_without_coding
    [ "Self Pay", "self pay", "SELF PAY", "  self pay  " ].each do |label|
      patient_id = "pt_d2_text_#{label.gsub(/\s+/, '_').downcase}"
      resource = issue_607_organization_coverage(
        id: "cov_d2_text",
        for_patient: patient_id,
        type_text: label
      )
      assert_single_excluded_issue_607_coverage(patient_id, resource,
                                                "type.text #{label.inspect} without coding")
    end
  end

  # D3 — non-SOP codings keep prior insurance rules (issue #607)

  def test_get_coverages_includes_active_coverage_with_ehcpol_type_and_organization_org_1_payor
    resource = issue_607_organization_coverage(
      id: "cov_d3_ehcpol",
      for_patient: "pt_d3_ehcpol",
      type_code: "EHCPOL"
    )
    assert_single_included_issue_607_coverage("pt_d3_ehcpol", resource, "EHCPOL with Organization/org_1")
  end

  # S2 — malformed Coverage shapes => nil (never raise)

  MALFORMED_COVERAGE_SHAPE_CASES = [
    [ "type is string", ->(r) { r["type"] = "pay" } ],
    [ "payor is array of strings", ->(r) { r["payor"] = [ "Organization/o" ] } ],
    [ "beneficiary is string", ->(r) { r["beneficiary"] = "Patient/pt_001" } ],
    [ "class entry type is string", ->(r) { r["class"] = [ { "type" => "plan" } ] } ],
    [ "type.coding is string", ->(r) { r["type"] = { "coding" => "x" } } ],
    [ "period.start is integer", ->(r) { r["period"] = { "start" => 5 } } ]
  ].freeze

  def test_get_coverages_returns_nil_for_malformed_coverage_shapes_without_raising
    MALFORMED_COVERAGE_SHAPE_CASES.each do |label, mutate|
      resource = coverage_fhir_resource(
        id: "cov_s2_shape",
        for_patient: "pt_s2_shape",
        status: "active",
        payer_display: "TEST PAYER SHAPE",
        type_code: "EHCPOL",
        subscriber_id: "POL_SHAPE",
        period_start: Date.new(2026, 1, 1),
        period_end: Date.new(2026, 12, 31)
      )
      mutate.call(resource)
      bundle = coverage_bundle_total_one(resource)
      with_stubbed_coverage_http({ coverage_search_url("pt_s2_shape") => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages("pt_s2_shape"), "expected nil for malformed shape: #{label}"
      end
    end
  end

  # S3 — Bundle.total must be a non-negative Integer when present

  INVALID_COVERAGE_BUNDLE_TOTALS = [ "5", 1.5, -1 ].freeze

  def test_get_coverages_returns_nil_when_bundle_total_is_not_a_non_negative_integer
    base = coverage_fhir_resource(
      id: "cov_s3_total",
      for_patient: "pt_s3_total",
      status: "active",
      payer_display: "TEST PAYER TOTAL",
      type_code: "EHCPOL",
      subscriber_id: "POL_S3",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    INVALID_COVERAGE_BUNDLE_TOTALS.each do |bad_total|
      bundle = coverage_bundle(entries: [ base ], total: bad_total)
      with_stubbed_coverage_http({ coverage_search_url("pt_s3_total") => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages("pt_s3_total"),
                   "expected nil when bundle total is #{bad_total.inspect}"
      end
    end
  end

  # S4 — Coverage.status must be a known FHIR code (case-sensitive)

  INVALID_COVERAGE_STATUS_VALUES = [ "Active", "unknown" ].freeze

  def test_get_coverages_returns_nil_when_coverage_status_is_not_a_known_fhir_code
    INVALID_COVERAGE_STATUS_VALUES.each do |bad_status|
      resource = coverage_fhir_resource(
        id: "cov_s4_status",
        for_patient: "pt_s4_status",
        status: bad_status,
        payer_display: "TEST PAYER STATUS",
        type_code: "EHCPOL",
        subscriber_id: "POL_S4",
        period_start: Date.new(2026, 1, 1),
        period_end: Date.new(2026, 12, 31)
      )
      bundle = coverage_bundle_total_one(resource)
      with_stubbed_coverage_http({ coverage_search_url("pt_s4_status") => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages("pt_s4_status"),
                   "expected nil for invalid status #{bad_status.inspect}"
      end
    end
  end

  # S5 — Net::ProtocolError (base class) => nil

  def test_get_coverages_returns_nil_when_http_get_raises_net_protocol_error
    with_stubbed_coverage_http(lambda { |_url| raise Net::ProtocolError, "protocol error" }) do
      assert_nil @adapter.get_coverages("pt_s5_protocol")
    end
  end

  def test_get_coverages_follows_next_link_when_relation_is_capitalized_next
    page1_url = coverage_search_url("pt_next_case")
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/pt_next_case")}"
    page1 = {
      "resourceType" => "Bundle",
      "entry" => [
        { "resource" => coverage_fhir_resource(
          id: "cov_nc1",
          for_patient: "pt_next_case",
          status: "active",
          payer_display: "TEST PAYER NC1",
          type_code: "MCDSC",
          subscriber_id: "POL_NC1",
          period_start: Date.new(2026, 1, 1)
        ) }
      ],
      "link" => [ { "relation" => "Next", "url" => page2_url } ]
    }
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_nc2",
          for_patient: "pt_next_case",
          status: "active",
          payer_display: "TEST PAYER NC2",
          type_code: "EHCPOL",
          subscriber_id: "POL_NC2",
          period_start: Date.new(2026, 2, 1)
        )
      ]
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      result = @adapter.get_coverages("pt_next_case")
      assert_equal 2, result.size
      assert_equal [ page1_url, page2_url ], @requested_urls
    end
  end

  private

  def coverage_search_url(patient_identifier)
    query = URI.encode_www_form(beneficiary: "Patient/#{patient_identifier}")
    "#{@adapter.base_url}/Coverage?#{query}"
  end

  def coverage_bundle(entries:, next_url: nil, next_relation: "next", total: nil)
    bundle = {
      "resourceType" => "Bundle",
      "entry" => entries.map { |entry|
        entry.is_a?(Hash) && entry.key?("resource") ? entry : { "resource" => entry }
      }
    }
    bundle["total"] = total unless total.nil?
    if next_url
      bundle["link"] = [ { "relation" => next_relation, "url" => next_url } ]
    end
    bundle
  end

  def coverage_bundle_total_one(resource, total: 1)
    coverage_bundle(entries: [ resource ], total: total)
  end

  def assert_single_excluded_coverage_returns_empty(patient_id, resource)
    bundle = coverage_bundle_total_one(resource)
    with_stubbed_coverage_http({ coverage_search_url(patient_id) => http_ok_json(bundle) }) do
      assert_equal [], @adapter.get_coverages(patient_id),
                   "single Coverage with total 1 must return [] when excluded from insurance allowlist"
    end
  end

  def issue_607_organization_coverage(id:, for_patient:, type_codings: nil, type_code: nil, type_text: nil)
    coverage_fhir_resource(
      id: id,
      for_patient: for_patient,
      status: "active",
      payer_display: "TEST PAYER #{id.upcase}",
      subscriber_id: "POL_#{id.upcase}",
      payor_reference: "Organization/org_1",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31),
      type_codings: type_codings,
      type_code: type_code,
      type_text: type_text
    )
  end

  def assert_single_included_issue_607_coverage(patient_id, resource, context)
    bundle = coverage_bundle_total_one(resource)
    with_stubbed_coverage_http({ coverage_search_url(patient_id) => http_ok_json(bundle) }) do
      result = @adapter.get_coverages(patient_id)
      assert_equal 1, result.size, "expected included coverage for #{context}"
    end
  end

  def assert_single_excluded_issue_607_coverage(patient_id, resource, context)
    bundle = coverage_bundle_total_one(resource)
    with_stubbed_coverage_http({ coverage_search_url(patient_id) => http_ok_json(bundle) }) do
      result = @adapter.get_coverages(patient_id)
      assert_equal [], result, "expected [] for excluded coverage: #{context}"
    end
  end

  def coverage_fhir_resource(id:, payer_display:, type_code: nil, subscriber_id:,
                             status: "active",
                             period_start: nil, period_end: nil, period: nil,
                             plan_name: nil, plan_value: nil,
                             for_patient: nil, beneficiary_reference: nil,
                             payor_reference: :auto,
                             payors: nil, type_codings: nil, type_text: nil,
                             kind: nil, payment_by: nil, skip_payor: false)
    resource = {
      "resourceType" => "Coverage",
      "id" => id,
      "status" => status,
      "subscriberId" => subscriber_id
    }
    unless skip_payor
      resource["payor"] = if payors
        payors
      else
        payor = { "display" => payer_display }
        ref = payor_reference == :auto ? "Organization/#{id}" : payor_reference
        payor["reference"] = ref if ref
        [ payor ]
      end
    end
    if type_codings
      resource["type"] = { "coding" => type_codings }
      resource["type"]["text"] = type_text if type_text
    elsif type_code
      resource["type"] = { "coding" => [ { "code" => type_code } ] }
      resource["type"]["text"] = type_text if type_text
    elsif type_text
      resource["type"] = { "text" => type_text }
    end
    resource["kind"] = kind if kind
    resource["paymentBy"] = payment_by if payment_by
    if beneficiary_reference
      resource["beneficiary"] = { "reference" => beneficiary_reference }
    elsif for_patient
      resource["beneficiary"] = { "reference" => "Patient/#{for_patient}" }
    end
    if period
      resource["period"] = period
    else
      resource["period"] = {}
      if period_start.is_a?(Date)
        resource["period"]["start"] = period_start.iso8601
      elsif period_start
        resource["period"]["start"] = period_start
      end
      if period_end.is_a?(Date)
        resource["period"]["end"] = period_end.iso8601
      elsif period_end
        resource["period"]["end"] = period_end
      end
    end
    if plan_name || plan_value
      plan_entry = { "type" => { "coding" => [ { "code" => "plan" } ] } }
      plan_entry["name"] = plan_name if plan_name
      plan_entry["value"] = plan_value if plan_value
      resource["class"] = [ plan_entry ]
    end
    resource
  end

  def http_ok_json(body_hash)
    http_ok_body(body_hash.to_json)
  end

  def http_ok_body(body)
    consumed_http_response(Net::HTTPOK, "200", "OK", body)
  end

  def http_error_response(klass, code, message, body = "")
    consumed_http_response(klass, code, message, body)
  end

  def consumed_http_response(klass, code, message, body)
    klass.new("1.1", code, message).tap do |resp|
      resp.instance_variable_set(:@read, true)
      resp.instance_variable_set(:@body, body)
    end
  end

  def with_stubbed_coverage_http(responses_by_url, now: nil)
    @requested_urls = []
    impl = if responses_by_url.respond_to?(:call)
      responses_by_url
    else
      lambda do |url|
        response = responses_by_url.fetch(url) { raise KeyError, "unexpected http_get URL: #{url}" }
        response.respond_to?(:call) ? response.call : response
      end
    end
    wrapped = lambda do |url|
      @requested_urls << url
      impl.call(url)
    end
    pinned_now = now || FIXED_COVERAGE_TODAY.to_time
    Time.stub(:current, pinned_now) do
      Date.stub(:current, FIXED_COVERAGE_TODAY) do
        Date.stub(:today, FIXED_COVERAGE_TODAY) do
          @adapter.stub(:http_get, wrapped) { yield }
        end
      end
    end
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
