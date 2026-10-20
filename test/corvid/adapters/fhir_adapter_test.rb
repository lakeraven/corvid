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
          status: "cancelled",
          payer_display: "TEST PAYER 002",
          type_code: "EHCPOL",
          subscriber_id: "POL_002",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        ),
        coverage_fhir_resource(
          id: "cov_expired",
          status: "active",
          payer_display: "TEST PAYER 003",
          type_code: "MCRSC",
          subscriber_id: "POL_003",
          period_start: Date.new(2024, 1, 1),
          period_end: Date.new(2025, 12, 31)
        ),
        coverage_fhir_resource(
          id: "cov_future",
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
      entries: [ coverage_fhir_resource(id: "cov_a", status: "active", payer_display: "TEST PAYER 503",
                                        type_code: "MCDSC", subscriber_id: "POL_503") ],
      next_url: page2_url
    )
    with_stubbed_coverage_http({
      page1_url => http_ok_json(page1),
      page2_url => Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable").tap { |r| r.body = "" }
    }) do
      assert_nil @adapter.get_coverages("pt_503")
    end
  end

  def test_get_coverages_returns_nil_when_first_page_returns_500
    page1_url = coverage_search_url("pt_500")
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/pt_500")}"
    with_stubbed_coverage_http({
      page1_url => Net::HTTPInternalServerError.new("1.1", "500", "Error").tap { |r| r.body = "" },
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
      entries: [ coverage_fhir_resource(id: "cov_x", status: "active", payer_display: "TEST PAYER X",
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
      entries: [ coverage_fhir_resource(id: "cov_loop1", status: "active", payer_display: "TEST PAYER LOOP1",
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

  private

  def coverage_search_url(patient_identifier)
    query = URI.encode_www_form(beneficiary: "Patient/#{patient_identifier}")
    "#{@adapter.base_url}/Coverage?#{query}"
  end

  def coverage_bundle(entries:, next_url: nil)
    bundle = {
      "resourceType" => "Bundle",
      "entry" => entries.map { |resource| { "resource" => resource } }
    }
    if next_url
      bundle["link"] = [ { "relation" => "next", "url" => next_url } ]
    end
    bundle
  end

  def coverage_fhir_resource(id:, status:, payer_display:, type_code:, subscriber_id:,
                             period_start: nil, period_end: nil,
                             plan_name: nil, plan_value: nil)
    resource = {
      "resourceType" => "Coverage",
      "id" => id,
      "status" => status,
      "payor" => [ { "display" => payer_display } ],
      "subscriberId" => subscriber_id,
      "type" => { "coding" => [ { "code" => type_code } ] },
      "period" => {}
    }
    resource["period"]["start"] = period_start.iso8601 if period_start
    resource["period"]["end"] = period_end.iso8601 if period_end
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
    Net::HTTPOK.new("1.1", "200", "OK").tap { |r| r.body = body }
  end

  def with_stubbed_coverage_http(responses_by_url)
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
    Date.stub(:current, FIXED_COVERAGE_TODAY) do
      Date.stub(:today, FIXED_COVERAGE_TODAY) do
        @adapter.stub(:http_get, wrapped) { yield }
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
