# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "json"
require "net/http"
require "net/protocol"
require "uri"
require "zlib"
require "active_support/all" # adapter uses AS ext (Time.current, String#last, present?); loaded by the host app in real use
require "active_support/testing/time_helpers"
require "corvid/adapters/fhir_adapter"

class Corvid::Adapters::FhirAdapterTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  def setup
    @saved_time_zone = Time.zone
    Time.zone = "UTC"
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
  end

  def teardown
    Time.zone = @saved_time_zone
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
      "type" => "searchset",
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
      "type" => "searchset",
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
      "type" => "searchset",
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
      "type" => "searchset",
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
      "type" => "searchset",
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
      "type" => "searchset",
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
      "type" => "searchset",
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
      "type" => "searchset",
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
      # amount_error reaches reporting output, so the server-supplied value
      # is described rather than echoed — same rule as the auth path.
      refute_match(/not-a-number/, line.amount_error)
      assert_match(/12-character String/, line.amount_error)
    end
  end

  def test_list_claims_absent_amount_is_legit_nil_without_error
    bundle = {
      "resourceType" => "Bundle",
      "type" => "searchset",
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
      "type" => "searchset",
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

  def test_verify_tribal_enrollment_missing_confidence_sub_extension_is_unavailable
    resource = {
      "id" => "pt_no_conf",
      "extension" => [ {
        "url" => "https://lakeraven.com/fhir/StructureDefinition/tribal-enrollment",
        "extension" => [
          { "url" => "enrolled", "valueBoolean" => true },
          { "url" => "membershipNumber", "valueString" => "TGN-100255" },
          { "url" => "tribeName", "valueString" => "Tallgrass Nation" },
          { "url" => "tribeCode", "valueString" => "TGN" }
        ]
      } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_no_conf")
      assert_equal true, result[:enrolled]
      assert_equal :unavailable, result[:confidence]
    end
  end

  def test_verify_tribal_enrollment_explicit_stale_confidence_passes_through
    resource = {
      "id" => "pt_stale",
      "extension" => [ {
        "url" => "https://lakeraven.com/fhir/StructureDefinition/tribal-enrollment",
        "extension" => [
          { "url" => "enrolled", "valueBoolean" => true },
          { "url" => "tribeCode", "valueString" => "TGN" },
          { "url" => "confidence", "valueString" => "stale" }
        ]
      } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_stale")
      assert_equal :stale, result[:confidence]
    end
  end

  def test_verify_tribal_enrollment_falls_back_when_extension_absent
    # Issue #662 round 4: missing extension is unknown enrollment, not a firm false.
    @adapter.stub(:fhir_read, { "id" => "pt_001" }) do
      result = @adapter.verify_tribal_enrollment("pt_001")
      assert_nil result[:enrolled]
      assert_equal :unavailable, result[:confidence]
    end
  end

  def test_verify_tribal_enrollment_returns_nil_enrolled_when_patient_read_fails
    @adapter.stub(:fhir_read, nil) do
      result = @adapter.verify_tribal_enrollment("pt_missing")
      assert_nil result[:enrolled]
      assert_equal :unavailable, result[:confidence]
    end
  end

  # Issue #662 round 2: missing or non-boolean enrolled sub-extension => nil enrolled.

  def test_verify_tribal_enrollment_missing_enrolled_sub_extension_returns_nil_enrolled
    resource = {
      "id" => "pt_no_enrolled_sub",
      "extension" => [ {
        "url" => TRIBAL_ENROLLMENT_EXTENSION_URL,
        "extension" => [
          { "url" => "tribeCode", "valueString" => "TGN" },
          { "url" => "confidence", "valueString" => "verified" }
        ]
      } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_no_enrolled_sub")
      assert_nil result[:enrolled]
      assert_equal :verified, result[:confidence]
    end
  end

  def test_verify_tribal_enrollment_non_boolean_enrolled_sub_extension_returns_nil_enrolled
    resource = {
      "id" => "pt_str_enrolled",
      "extension" => [ {
        "url" => TRIBAL_ENROLLMENT_EXTENSION_URL,
        "extension" => [
          { "url" => "enrolled", "valueString" => "true" },
          { "url" => "tribeCode", "valueString" => "TGN" },
          { "url" => "confidence", "valueString" => "verified" }
        ]
      } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_str_enrolled")
      assert_nil result[:enrolled]
    end
  end

  def test_verify_tribal_enrollment_value_boolean_false_returns_false_enrolled
    resource = {
      "id" => "pt_enrolled_false",
      "extension" => [ {
        "url" => TRIBAL_ENROLLMENT_EXTENSION_URL,
        "extension" => [
          { "url" => "enrolled", "valueBoolean" => false },
          { "url" => "tribeCode", "valueString" => "TGN" },
          { "url" => "confidence", "valueString" => "verified" }
        ]
      } ]
    }
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_enrolled_false")
      assert_equal false, result[:enrolled]
    end
  end

  # Issue #662: confidence sub-extension is allow-listed; anything else is :unavailable.

  def test_verify_tribal_enrollment_confidence_allow_lists_verified_stale_unavailable_strings
    %w[verified stale unavailable].each do |word|
      resource = tribal_enrollment_patient("pt_conf_#{word}", confidence_sub: { "valueString" => word })
      @adapter.stub(:fhir_read, resource) do
        result = @adapter.verify_tribal_enrollment("pt_conf_#{word}")
        assert_equal word.to_sym, result[:confidence]
      end
    end
  end

  def test_verify_tribal_enrollment_confidence_blank_string_is_unavailable
    resource = tribal_enrollment_patient("pt_conf_blank", confidence_sub: { "valueString" => "" })
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_conf_blank")
      assert_equal :unavailable, result[:confidence]
    end
  end

  %w[VERIFIED unverified probable].each do |bad|
    define_method("test_verify_tribal_enrollment_confidence_#{bad.downcase}_string_is_unavailable") do
      resource = tribal_enrollment_patient("pt_bad_#{bad}", confidence_sub: { "valueString" => bad })
      @adapter.stub(:fhir_read, resource) do
        result = @adapter.verify_tribal_enrollment("pt_bad_#{bad}")
        assert_equal :unavailable, result[:confidence]
      end
    end
  end

  def test_verify_tribal_enrollment_confidence_value_decimal_is_unavailable_without_raising
    resource = tribal_enrollment_patient("pt_conf_dec", confidence_sub: { "valueDecimal" => 0.2 })
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_conf_dec")
      assert_equal :unavailable, result[:confidence]
    end
  end

  def test_verify_tribal_enrollment_confidence_value_boolean_true_is_unavailable_without_raising
    resource = tribal_enrollment_patient("pt_conf_bool_t", confidence_sub: { "valueBoolean" => true })
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_conf_bool_t")
      assert_equal :unavailable, result[:confidence]
    end
  end

  def test_verify_tribal_enrollment_confidence_value_boolean_false_is_unavailable_without_raising
    resource = tribal_enrollment_patient("pt_conf_bool_f", confidence_sub: { "valueBoolean" => false })
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_conf_bool_f")
      assert_equal :unavailable, result[:confidence]
    end
  end

  def test_verify_tribal_enrollment_confidence_value_code_is_unavailable_without_raising
    resource = tribal_enrollment_patient("pt_conf_code", confidence_sub: {
      "valueCode" => "verified",
      "system" => "http://example.test/confidence"
    })
    @adapter.stub(:fhir_read, resource) do
      result = @adapter.verify_tribal_enrollment("pt_conf_code")
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

  # Issue #662: a transport failure is an unavailable source, not an exception.
  # The fault is raised from the HTTP request so fhir_read/http_get run for real.

  VERIFICATION_TRANSPORT_ERRORS = [
    Errno::ECONNREFUSED,
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError,
    OpenSSL::SSL::SSLError,
    EOFError,
    Net::ProtocolError
  ].freeze

  VERIFICATION_TRANSPORT_ERRORS.each do |error_class|
    slug = error_class.name.gsub("::", "_").downcase

    define_method("test_verify_tribal_enrollment_#{slug}_is_unavailable") do
      with_transport_failure(error_class) do
        result = @adapter.verify_tribal_enrollment("pt_test_001")
        assert_nil result[:enrolled]
        assert_equal :unavailable, result[:confidence]
        assert_nil result[:tribe_code]
        assert_nil result[:membership_number]
      end
    end

    define_method("test_verify_identity_documents_#{slug}_reports_nothing_present") do
      with_transport_failure(error_class) do
        result = @adapter.verify_identity_documents("pt_test_001")
        assert_equal false, result[:ssn_present]
        assert_equal false, result[:dob_present]
        assert_equal false, result[:birthplace_present]
      end
    end

    define_method("test_verify_residency_#{slug}_is_not_on_reservation") do
      with_transport_failure(error_class) do
        result = @adapter.verify_residency("pt_test_001")
        assert_equal false, result[:on_reservation]
        assert_nil result[:address]
        assert_nil result[:service_area]
      end
    end
  end

  # -- get_conditions / get_medications (issue #611) --------------------------

  CONDITION_CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-category"
  US_CORE_CONDITION_CATEGORY_SYSTEM = "http://hl7.org/fhir/us/core/CodeSystem/condition-category"
  CONDITION_CLINICAL_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-clinical"
  CONDITION_VER_STATUS_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-ver-status"

  LATER_CODED_CONCEPT = {
    "coding" => [
      { "system" => "urn:local:ehr" },
      { "system" => "http://example.test/rx", "code" => "M001", "display" => "TEST MEDICATION 001" }
    ]
  }.freeze

  CLINICAL_HTTP_FAULTS = [
    Net::HTTPBadResponse.new("bad response"),
    Net::HTTPHeaderSyntaxError.new("bad header"),
    Zlib::DataError.new,
    Net::ProtocolError.new("protocol error")
  ].freeze

  INVALID_STRICT_DATE_STRINGS = %w[Tuesday the\ 5th Friday 2026/01/05 20260105].freeze

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
    skipped = build_condition_resource(id: "cond_skipped", category_code: "health-concern")
    results = get_conditions_with_bundle(conditions_bundle([ included, skipped ]))

    assert_equal 1, results.size
    assert_equal "problem-list-item", results.first.category
  end

  def test_get_conditions_skips_non_active_or_resolved_clinical_status
    included = build_condition_resource(clinical_status: "resolved")
    skipped = build_condition_resource(id: "cond_skipped", clinical_status: "inactive")
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

  # -- Issue #611 panel round 1: strict clinical read behaviour (failing until implemented) --

  CLINICAL_HTTP_FAULTS.each do |fault|
    define_method(:"test_get_conditions_returns_nil_when_http_get_raises_#{fault.class.name.split('::').last}") do
      assert_nil clinical_read_with_http_fault(:get_conditions, fault)
    end

    define_method(:"test_get_medications_returns_nil_when_http_get_raises_#{fault.class.name.split('::').last}") do
      assert_nil clinical_read_with_http_fault(:get_medications, fault)
    end
  end

  INVALID_STRICT_DATE_STRINGS.each do |bad_onset|
    define_method(:"test_get_conditions_returns_nil_when_onset_is_#{bad_onset.gsub(/\W+/, '_')}") do
      condition = build_condition_resource(onsetDateTime: bad_onset)
      assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
    end
  end

  def test_get_conditions_keeps_row_with_nil_onset_for_year_only_onset_date_time
    condition = build_condition_resource(onsetDateTime: "2020")
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_kind_of Array, results
    assert_equal 1, results.size
    assert_nil results.first.onset_date
  end

  def test_get_conditions_keeps_row_with_nil_onset_for_year_month_onset_date_time
    condition = build_condition_resource(onsetDateTime: "2020-03")
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_kind_of Array, results
    assert_equal 1, results.size
    assert_nil results.first.onset_date
  end

  def test_get_conditions_maps_full_onset_date_time_to_date_part
    condition = build_condition_resource(onsetDateTime: "2020-03-15T14:30:00.123-05:00")
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal Date.new(2020, 3, 15), results.first.onset_date
  end

  def test_get_conditions_returns_nil_when_onset_period_start_is_invalid_strict_date
    condition = build_condition_resource(onsetDateTime: nil, onsetPeriod: { "start" => "Friday" })
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_keeps_row_with_nil_onset_for_partial_onset_period_start
    condition = build_condition_resource(onsetDateTime: nil, onsetPeriod: { "start" => "2019-07" })
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_kind_of Array, results
    assert_equal 1, results.size
    assert_nil results.first.onset_date
  end

  INVALID_STRICT_DATE_STRINGS.each do |bad_authored|
    define_method(:"test_get_medications_returns_nil_when_authored_on_is_#{bad_authored.gsub(/\W+/, '_')}") do
      request = build_medication_request_resource(authoredOn: bad_authored)
      assert_nil get_medications_with_bundle(medications_bundle([ request ]))
    end
  end

  def test_get_medications_keeps_row_with_nil_authored_on_for_year_only
    request = build_medication_request_resource(authoredOn: "2020")
    results = get_medications_with_bundle(medications_bundle([ request ]))

    assert_kind_of Array, results
    assert_equal 1, results.size
    assert_nil results.first.authored_on
  end

  def test_get_medications_maps_full_authored_on_date_time_to_date_part
    request = build_medication_request_resource(authoredOn: "2024-06-01T08:15:00Z")
    results = get_medications_with_bundle(medications_bundle([ request ]))

    assert_equal Date.new(2024, 6, 1), results.first.authored_on
  end

  def test_get_conditions_excludes_refuted_verification_status
    refuted = build_condition_resource(verification_status: "refuted")
    active = build_condition_resource("id" => "cond_active", verification_status: "confirmed")
    results = get_conditions_with_bundle(conditions_bundle([ refuted, active ]))

    assert_equal 1, results.size
    assert_equal "active", results.first.clinical_status
  end

  def test_get_conditions_excludes_entered_in_error_verification_status_in_any_coding_position
    condition = build_condition_resource(
      verification_status_codings: [
        { "system" => "http://example.test/local", "code" => "ok" },
        { "system" => CONDITION_VER_STATUS_SYSTEM, "code" => "entered-in-error" }
      ]
    )
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal [], results
  end

  def test_get_conditions_uses_condition_clinical_system_coding_not_first_arbitrary_coding
    condition = build_condition_resource(
      clinical_status_codings: [
        { "system" => "http://example.test/local", "code" => "A" },
        { "system" => CONDITION_CLINICAL_SYSTEM, "code" => "active" }
      ]
    )
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    assert_equal "active", results.first.clinical_status
  end

  %w[recurrence relapse].each do |status|
    define_method(:"test_get_conditions_includes_clinical_status_#{status}") do
      condition = build_condition_resource(
        clinical_status: status,
        clinical_status_system: CONDITION_CLINICAL_SYSTEM
      )
      results = get_conditions_with_bundle(conditions_bundle([ condition ]))

      assert_equal 1, results.size
      assert_equal status, results.first.clinical_status
    end
  end

  def test_get_conditions_returns_nil_when_condition_clinical_code_is_not_fhir_allowed
    condition = build_condition_resource(
      clinical_status: "Active",
      clinical_status_system: CONDITION_CLINICAL_SYSTEM
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  %w[inactive remission].each do |status|
    define_method(:"test_get_conditions_excludes_clinical_status_#{status}") do
      skipped = build_condition_resource(
        clinical_status: status,
        clinical_status_system: CONDITION_CLINICAL_SYSTEM
      )
      included = build_condition_resource(id: "cond_ok", clinical_status: "active",
                                        clinical_status_system: CONDITION_CLINICAL_SYSTEM)
      results = get_conditions_with_bundle(conditions_bundle([ skipped, included ]))

      assert_equal 1, results.size
    end
  end

  def test_get_conditions_returns_nil_when_subject_is_absolute_patient_on_other_host
    condition = build_condition_resource(
      subject: { "reference" => "https://other-ehr.example/fhir/Patient/pt_001" }
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_returns_nil_when_subject_reference_is_group_patient_path
    condition = build_condition_resource(subject: { "reference" => "Group/Patient/pt_001" })
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_accepts_subject_reference_under_base_url
    condition = build_condition_resource(
      subject: { "reference" => "#{@adapter.base_url}/Patient/pt_001" }
    )
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
  end

  def test_get_medications_returns_nil_when_duplicate_contained_medication_ids
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "#m1" },
      contained: [
        { "resourceType" => "Medication", "id" => "m1", "code" => { "coding" => [ { "code" => "M1" } ] } },
        { "resourceType" => "Medication", "id" => "m1", "code" => { "coding" => [ { "code" => "M2" } ] } }
      ]
    )
    assert_nil get_medications_with_bundle(medications_bundle([ request ]))
  end

  def test_get_medications_returns_nil_when_duplicate_bundled_medication_ids
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "Medication/m1" }
    )
    dup_med = { "resourceType" => "Medication", "id" => "m1",
                "code" => { "coding" => [ { "code" => "M001" } ] } }
    bundle = medications_bundle([ request ], includes: [ dup_med, dup_med ])
    assert_nil get_medications_with_bundle(bundle)
  end

  def test_get_medications_returns_nil_when_medication_reference_absolute_off_base_url
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "https://other-ehr.example/fhir/Medication/m1" }
    )
    included = {
      "resourceType" => "Medication", "id" => "m1",
      "code" => { "coding" => [ { "code" => "M001" } ] }
    }
    assert_nil get_medications_with_bundle(medications_bundle([ request ], includes: [ included ]))
  end

  def test_get_medications_resolves_medication_reference_under_base_url
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "#{@adapter.base_url}/Medication/m1" }
    )
    included = {
      "resourceType" => "Medication", "id" => "m1",
      "code" => { "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M001" } ] }
    }
    results = get_medications_with_bundle(medications_bundle([ request ], includes: [ included ]))

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
  end

  %w[? ??].each do |bad_ref|
    define_method(:"test_get_medications_returns_nil_for_malformed_medication_reference_#{bad_ref.gsub('?', 'q')}") do
      request = build_medication_request_resource(
        medicationCodeableConcept: nil,
        medicationReference: { "reference" => bad_ref }
      )
      assert_nil get_medications_with_bundle(medications_bundle([ request ]))
    end
  end

  def test_get_medications_returns_nil_for_blank_medication_reference
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "" }
    )
    assert_nil get_medications_with_bundle(medications_bundle([ request ]))
  end

  def test_get_medications_returns_nil_when_medication_codeable_concept_empty_without_reference
    request = build_medication_request_resource(medicationReference: nil)
    request["medicationCodeableConcept"] = {}
    request.delete("medicationReference")
    assert_nil get_medications_with_bundle(medications_bundle([ request ]))
  end

  def test_get_conditions_skips_bundle_include_entries_that_are_not_conditions
    condition = build_condition_resource
    patient = { "resourceType" => "Patient", "id" => "pt_001" }
    bundle = conditions_bundle([ condition ], includes: [ patient ])
    results = get_conditions_with_bundle(bundle)

    assert_equal 1, results.size
  end

  def test_get_conditions_returns_nil_when_bundle_has_unexpected_resource_without_include_mode
    condition = build_condition_resource
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [
        { "resource" => condition },
        { "resource" => { "resourceType" => "Provenance", "id" => "prov_1" } }
      ]
    }
    assert_nil get_conditions_with_bundle(bundle)
  end

  def test_get_medications_skips_bundle_include_entries_that_are_not_medication_resources
    request = build_medication_request_resource
    patient = { "resourceType" => "Patient", "id" => "pt_001" }
    results = get_medications_with_bundle(medications_bundle([ request ], includes: [ patient ]))

    assert_equal 1, results.size
  end

  def test_get_medications_returns_nil_when_bundle_has_unexpected_resource_without_include_mode
    request = build_medication_request_resource
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [
        { "resource" => request, "search" => { "mode" => "match" } },
        { "resource" => { "resourceType" => "Provenance", "id" => "prov_1" } }
      ]
    }
    assert_nil get_medications_with_bundle(bundle)
  end

  def test_get_conditions_returns_nil_for_blank_patient_identifier_without_http
    assert_nil clinical_read_without_http(:get_conditions, "")
  end

  def test_get_conditions_returns_nil_for_nil_patient_identifier_without_http
    assert_nil clinical_read_without_http(:get_conditions, nil)
  end

  def test_get_medications_returns_nil_for_blank_patient_identifier_without_http
    assert_nil clinical_read_without_http(:get_medications, "   ")
  end

  # -- Issue #611 panel round 2: strict clinical read behaviour (failing until implemented) --

  def test_get_conditions_returns_nil_on_http_204_no_content
    response = no_content_http_response
    assert_nil get_conditions_with_http_response(response)
  end

  def test_get_medications_returns_nil_on_http_204_no_content
    response = no_content_http_response
    assert_nil get_medications_with_http_response(response)
  end

  def test_get_conditions_returns_nil_when_http_get_raises_runtime_error
    assert_nil clinical_read_with_http_fault(:get_conditions, RuntimeError.new("synthetic fault"))
  end

  def test_get_medications_returns_nil_when_http_get_raises_runtime_error
    assert_nil clinical_read_with_http_fault(:get_medications, RuntimeError.new("synthetic fault"))
  end

  INVALID_MEDICATION_REFERENCE_IDS = {
    space: "a b",
    embedded_quote: %(a"b)
  }.freeze

  INVALID_MEDICATION_REFERENCE_IDS.each do |label, invalid_id|
    define_method(:"test_get_medications_returns_nil_for_invalid_medication_id_#{label}_without_http_read") do
      request = build_medication_request_resource(
        medicationCodeableConcept: nil,
        medicationReference: { "reference" => "Medication/#{invalid_id}" }
      )
      assert_nil get_medications_with_bundle_without_extra_http(medications_bundle([ request ]))
    end
  end

  def test_get_medications_excludes_medication_request_with_do_not_perform_true
    included = build_medication_request_resource("id" => "mr_ok")
    skipped = build_medication_request_resource("id" => "mr_skip", doNotPerform: true)
    results = get_medications_with_bundle(medications_bundle([ skipped, included ]))

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
  end

  def test_get_medications_returns_nil_when_contained_medication_has_no_code
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "#med_empty" },
      contained: [ { "resourceType" => "Medication", "id" => "med_empty", "code" => {} } ]
    )
    assert_nil get_medications_with_bundle(medications_bundle([ request ]))
  end

  def test_get_medications_returns_nil_when_bundled_medication_has_no_code
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "Medication/med_empty" }
    )
    included = { "resourceType" => "Medication", "id" => "med_empty", "code" => {} }
    assert_nil get_medications_with_bundle(medications_bundle([ request ], includes: [ included ]))
  end

  def test_get_conditions_returns_nil_when_clinical_status_missing
    condition = build_condition_resource.tap { |resource| resource.delete("clinicalStatus") }
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_returns_nil_when_clinical_status_is_text_only
    condition = build_condition_resource.tap do |resource|
      resource["clinicalStatus"] = { "text" => "active" }
    end
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_returns_nil_when_no_condition_clinical_system_coding
    condition = build_condition_resource(
      clinical_status_codings: [ { "system" => "http://example.test/local", "code" => "active" } ]
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_returns_nil_when_category_absent
    condition = build_condition_resource.tap { |resource| resource.delete("category") }
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_returns_nil_when_no_us_core_category_coding
    condition = build_condition_resource(
      category: [ { "coding" => [ { "system" => "http://example.test/local", "code" => "problem-list-item" } ] } ]
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_excludes_entered_in_error_even_when_clinical_status_unusable
    condition = build_condition_resource.tap { |resource| resource.delete("clinicalStatus") }
    condition["verificationStatus"] = {
      "coding" => [ { "system" => CONDITION_VER_STATUS_SYSTEM, "code" => "entered-in-error" } ]
    }
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal [], results
  end

  %w[refuted entered-in-error].each do |code|
    define_method(:"test_get_conditions_excludes_verification_status_#{code.tr('-', '_')}_in_foreign_system") do
      condition = build_condition_resource(
        verification_status_codings: [
          { "system" => "http://example.test/foreign-verification", "code" => code }
        ]
      )
      results = get_conditions_with_bundle(conditions_bundle([ condition ]))

      assert_equal [], results
    end
  end

  # -- Issue #611 panel round 3: strict clinical read behaviour (failing until implemented) --

  def test_get_medications_selects_first_coding_with_code_on_medication_codeable_concept
    request = build_medication_request_resource(medicationCodeableConcept: LATER_CODED_CONCEPT.dup)
    results = get_medications_with_bundle(medications_bundle([ request ]))

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
    assert_equal "http://example.test/rx", results.first.code_system
    assert_equal "TEST MEDICATION 001", results.first.display
  end

  def test_get_medications_selects_first_coding_with_code_on_contained_medication
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "#med1" },
      contained: [
        {
          "resourceType" => "Medication",
          "id" => "med1",
          "code" => LATER_CODED_CONCEPT.dup
        }
      ]
    )
    results = get_medications_with_bundle(medications_bundle([ request ]))

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
    assert_equal "http://example.test/rx", results.first.code_system
    assert_equal "TEST MEDICATION 001", results.first.display
  end

  def test_get_conditions_selects_first_coding_with_code_on_condition_code
    condition = build_condition_resource(code: LATER_CODED_CONCEPT.dup)
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
    assert_equal "http://example.test/rx", results.first.code_system
    assert_equal "TEST MEDICATION 001", results.first.display
  end

  def test_get_medications_returns_nil_when_no_coding_has_code_and_no_text
    request = build_medication_request_resource(
      medicationCodeableConcept: { "coding" => [ { "system" => "urn:local:ehr" }, { "system" => "http://example.test/rx", "display" => "NO CODE" } ] }
    )
    assert_nil get_medications_with_bundle(medications_bundle([ request ]))
  end

  def test_get_conditions_returns_nil_when_no_coding_has_code_and_no_text
    condition = build_condition_resource(
      code: { "coding" => [ { "system" => "urn:local:ehr" }, { "system" => "http://example.test/codes", "display" => "NO CODE" } ] }
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_display_from_text_when_no_coding_has_code
    condition = build_condition_resource(
      code: {
        "text" => "TEST CONDITION TEXT ONLY",
        "coding" => [ { "system" => "urn:local:ehr" }, { "system" => "http://example.test/codes", "display" => "" } ]
      }
    )
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    assert_nil results.first.code
    assert_equal "TEST CONDITION TEXT ONLY", results.first.display
  end

  def test_get_conditions_returns_nil_when_code_element_absent
    condition = build_condition_resource.tap { |resource| resource.delete("code") }
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_medications_excludes_medication_request_with_entered_in_error_status
    included = build_medication_request_resource("id" => "mr_cancelled", status: "cancelled")
    draft = build_medication_request_resource("id" => "mr_draft", status: "draft")
    skipped = build_medication_request_resource("id" => "mr_eie", status: "entered-in-error")
    results = get_medications_with_bundle(medications_bundle([ skipped, included, draft ]))

    assert_equal 2, results.size
    statuses = results.map(&:status).sort
    assert_equal %w[cancelled draft], statuses
  end

  def test_get_medications_returns_nil_when_bundled_medication_full_url_is_foreign_server
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "Medication/m1" }
    )
    included = {
      "resourceType" => "Medication",
      "id" => "m1",
      "code" => { "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M001" } ] }
    }
    bundle = medications_bundle(
      [ request ],
      includes: [ [ included, "https://other.example/fhir/Medication/m1" ] ]
    )
    assert_nil get_medications_with_bundle(bundle)
  end

  def test_get_medications_resolves_bundled_medication_when_full_url_matches_base_url
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "Medication/m1" }
    )
    included = {
      "resourceType" => "Medication",
      "id" => "m1",
      "code" => { "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M001" } ] }
    }
    bundle = medications_bundle(
      [ request ],
      includes: [ [ included, "#{@adapter.base_url}/Medication/m1" ] ]
    )
    results = get_medications_with_bundle(bundle)

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
  end

  def test_get_medications_resolves_bundled_medication_when_include_entry_has_no_full_url
    request = build_medication_request_resource(
      medicationCodeableConcept: nil,
      medicationReference: { "reference" => "Medication/m1" }
    )
    included = {
      "resourceType" => "Medication",
      "id" => "m1",
      "code" => { "coding" => [ { "system" => "http://example.test/rxnorm", "code" => "M001" } ] }
    }
    results = get_medications_with_bundle(medications_bundle([ request ], includes: [ included ]))

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
  end

  def test_get_conditions_returns_nil_when_bundle_type_is_not_searchset
    bundle = conditions_bundle([], type: "collection")
    assert_nil get_conditions_with_bundle(bundle)
  end

  def test_get_medications_returns_nil_when_bundle_type_is_not_searchset
    bundle = medications_bundle([], type: "collection")
    assert_nil get_medications_with_bundle(bundle)
  end

  def test_get_conditions_returns_nil_when_bundle_total_positive_but_no_entries
    bundle = conditions_bundle([], type: "searchset", total: 3)
    assert_nil get_conditions_with_bundle(bundle)
  end

  def test_get_medications_returns_nil_when_bundle_total_positive_but_no_match_entries
    bundle = medications_bundle([], type: "searchset", total: 2)
    assert_nil get_medications_with_bundle(bundle)
  end

  def test_get_conditions_returns_empty_array_when_bundle_total_zero_and_no_entries
    bundle = conditions_bundle([], type: "searchset", total: 0)
    assert_equal [], get_conditions_with_bundle(bundle)
  end

  def test_get_conditions_returns_empty_array_when_bundle_has_no_total_and_no_entries
    bundle = conditions_bundle([], type: "searchset", total: :omit)
    assert_equal [], get_conditions_with_bundle(bundle)
  end

  def test_get_conditions_skips_us_core_health_concern_category_while_returning_in_scope_rows
    included = build_condition_resource("id" => "cond_in_scope")
    skipped = build_condition_resource(
      "id" => "cond_health_concern",
      category: [ {
        "coding" => [ { "system" => US_CORE_CONDITION_CATEGORY_SYSTEM, "code" => "health-concern" } ]
      } ]
    )
    results = get_conditions_with_bundle(conditions_bundle([ skipped, included ]))

    refute_nil results, "page must not be unknown when only out-of-scope US Core categories are skipped"
    assert_equal 1, results.size
    assert_equal "problem-list-item", results.first.category
  end

  def test_get_conditions_returns_nil_when_clinical_status_codings_conflict
    condition = build_condition_resource(
      clinical_status_codings: [
        { "system" => CONDITION_CLINICAL_SYSTEM, "code" => "resolved" },
        { "system" => CONDITION_CLINICAL_SYSTEM, "code" => "active" }
      ]
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
  end

  def test_get_conditions_keeps_row_when_clinical_status_codings_are_identical
    condition = build_condition_resource(
      clinical_status_codings: [
        { "system" => CONDITION_CLINICAL_SYSTEM, "code" => "active" },
        { "system" => CONDITION_CLINICAL_SYSTEM, "code" => "active" }
      ]
    )
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal 1, results.size
    assert_equal "active", results.first.clinical_status
  end

  # -- Issue #611 panel round 4: spec amendment (failing until implemented) ----

  TRUST_DEFEATING_OUTCOME_CODES = %w[suppressed incomplete too-costly].freeze
  OUTCOME_SEVERITIES = %w[fatal error warning information].freeze

  TRUST_DEFEATING_OUTCOME_CODES.each do |issue_code|
    OUTCOME_SEVERITIES.each do |severity|
      define_method(:"test_get_conditions_returns_nil_when_operation_outcome_#{issue_code}_at_#{severity}") do
        condition = build_condition_resource
        bundle = conditions_bundle_with_operation_outcome([ condition ], issue_code: issue_code, severity: severity)
        assert_nil get_conditions_with_bundle(bundle)
      end

      define_method(:"test_get_medications_returns_nil_when_operation_outcome_#{issue_code}_at_#{severity}") do
        request = build_medication_request_resource
        bundle = medications_bundle_with_operation_outcome([ request ], issue_code: issue_code, severity: severity)
        assert_nil get_medications_with_bundle(bundle)
      end
    end
  end

  def test_get_conditions_keeps_list_when_operation_outcome_informational_at_information_severity
    condition = build_condition_resource
    bundle = conditions_bundle_with_operation_outcome(
      [ condition ], issue_code: "informational", severity: "information"
    )
    results = get_conditions_with_bundle(bundle)

    assert_equal 1, results.size
    assert_equal "C001", results.first.code
  end

  def test_get_medications_keeps_list_when_operation_outcome_informational_at_information_severity
    request = build_medication_request_resource
    bundle = medications_bundle_with_operation_outcome(
      [ request ], issue_code: "informational", severity: "information"
    )
    results = get_medications_with_bundle(bundle)

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
  end

  def test_get_medications_returns_nil_when_medication_request_status_absent
    request = build_medication_request_resource.tap { |resource| resource.delete("status") }
    assert_nil get_medications_with_bundle(medications_bundle([ request ]))
  end

  def test_get_medications_returns_nil_when_medication_request_status_outside_r4_value_set
    request = build_medication_request_resource(status: "planned")
    assert_nil get_medications_with_bundle(medications_bundle([ request ]))
  end

  def test_get_medications_returns_nil_when_do_not_perform_is_string_true
    request = build_medication_request_resource(doNotPerform: "true")
    assert_nil get_medications_with_bundle(medications_bundle([ request ]))
  end

  def test_get_medications_returns_nil_when_do_not_perform_is_non_boolean
    included = build_medication_request_resource("id" => "mr_ok")
    invalid = build_medication_request_resource("id" => "mr_bad", doNotPerform: "false")
    assert_nil get_medications_with_bundle(medications_bundle([ included, invalid ]))
  end

  def test_get_medications_keeps_row_when_do_not_perform_is_boolean_false
    request = build_medication_request_resource(doNotPerform: false)
    results = get_medications_with_bundle(medications_bundle([ request ]))

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
  end

  def test_get_conditions_excludes_refuted_verification_status_from_text_only
    condition = build_condition_resource.tap do |resource|
      resource["verificationStatus"] = { "text" => "REFUTED" }
    end
    active = build_condition_resource("id" => "cond_ok")
    results = get_conditions_with_bundle(conditions_bundle([ condition, active ]))

    assert_equal 1, results.size
    assert_equal "C001", results.first.code
  end

  def test_get_conditions_excludes_refuted_verification_status_from_stripped_text_only
    condition = build_condition_resource.tap do |resource|
      resource["verificationStatus"] = { "text" => "  Refuted  " }
    end
    active = build_condition_resource("id" => "cond_ok")
    results = get_conditions_with_bundle(conditions_bundle([ condition, active ]))

    assert_equal 1, results.size
    assert_equal "C001", results.first.code
  end

  def test_get_conditions_excludes_entered_in_error_verification_status_from_stripped_text_only
    condition = build_condition_resource.tap do |resource|
      resource["verificationStatus"] = { "text" => "  ENTERED-IN-ERROR  " }
    end
    results = get_conditions_with_bundle(conditions_bundle([ condition ]))

    assert_equal [], results
  end

  # -- Issue #611 spec amendment: pagination, totals, category, subject order --

  SELF_SEARCHSET_LINK = {
    "relation" => "self",
    "url" => "https://fhir.example.com/r4/Condition?patient=pt_001"
  }.freeze

  NEXT_SEARCHSET_LINK = {
    "relation" => "next",
    "url" => "https://fhir.example.com/r4/Condition?patient=pt_001&page=2"
  }.freeze

  def test_get_conditions_returns_nil_when_searchset_bundle_advertises_next_page_link
    condition = build_condition_resource
    bundle = searchset_bundle_with_links(conditions_bundle([ condition ]), [ SELF_SEARCHSET_LINK, NEXT_SEARCHSET_LINK ])

    assert_nil get_conditions_with_bundle(bundle)
  end

  def test_get_medications_returns_nil_when_searchset_bundle_advertises_next_page_link
    request = build_medication_request_resource
    bundle = searchset_bundle_with_links(medications_bundle([ request ]), [ SELF_SEARCHSET_LINK, NEXT_SEARCHSET_LINK ])

    assert_nil get_medications_with_bundle(bundle)
  end

  def test_get_conditions_returns_results_when_searchset_bundle_has_only_self_link
    condition = build_condition_resource
    bundle = searchset_bundle_with_links(conditions_bundle([ condition ]), [ SELF_SEARCHSET_LINK ])

    results = get_conditions_with_bundle(bundle)

    assert_equal 1, results.size
    assert_equal "C001", results.first.code
  end

  def test_get_medications_returns_results_when_searchset_bundle_has_only_self_link
    request = build_medication_request_resource
    bundle = searchset_bundle_with_links(medications_bundle([ request ]), [ SELF_SEARCHSET_LINK ])

    results = get_medications_with_bundle(bundle)

    assert_equal 1, results.size
    assert_equal "M001", results.first.code
  end

  def test_get_conditions_returns_nil_when_positive_total_has_only_informational_operation_outcome_without_search_mode
    bundle = positive_total_outcome_only_bundle(search_mode: :omit)
    assert_nil get_conditions_with_bundle(bundle)
  end

  def test_get_medications_returns_nil_when_positive_total_has_only_informational_operation_outcome_without_search_mode
    bundle = positive_total_outcome_only_bundle(search_mode: :omit)
    assert_nil get_medications_with_bundle(bundle)
  end

  def test_get_conditions_returns_nil_when_positive_total_has_only_informational_operation_outcome_in_outcome_mode
    bundle = positive_total_outcome_only_bundle(search_mode: "outcome")
    assert_nil get_conditions_with_bundle(bundle)
  end

  def test_get_medications_returns_nil_when_positive_total_has_only_informational_operation_outcome_in_outcome_mode
    bundle = positive_total_outcome_only_bundle(search_mode: "outcome")
    assert_nil get_medications_with_bundle(bundle)
  end

  %i[missing nil blank].each do |variant|
    define_method(:"test_get_conditions_returns_nil_when_us_core_category_code_is_#{variant}") do
      condition = build_condition_resource(category: [ us_core_category_element(variant) ])
      assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
    end

    define_method(:"test_get_conditions_returns_nil_when_hl7_category_code_is_#{variant}") do
      condition = build_condition_resource(category: [ hl7_category_element(variant) ])
      assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
    end
  end

  def test_get_conditions_still_skips_known_system_with_explicit_out_of_scope_category_code
    included = build_condition_resource("id" => "cond_in_scope")
    skipped = build_condition_resource(
      "id" => "cond_out_of_scope",
      category: [ {
        "coding" => [ { "system" => US_CORE_CONDITION_CATEGORY_SYSTEM, "code" => "health-concern" } ]
      } ]
    )
    results = get_conditions_with_bundle(conditions_bundle([ skipped, included ]))

    refute_nil results
    assert_equal 1, results.size
    assert_equal "problem-list-item", results.first.category
  end

  def test_get_medications_returns_nil_when_other_patient_request_has_do_not_perform_true
    request = build_medication_request_resource(
      subject: { "reference" => "Patient/pt_other" },
      doNotPerform: true
    )
    assert_nil get_medications_with_bundle(medications_bundle([ request ]), patient_id: "pt_001")
  end

  def test_get_medications_returns_nil_when_other_patient_request_has_entered_in_error_status
    request = build_medication_request_resource(
      subject: { "reference" => "Patient/pt_other" },
      status: "entered-in-error"
    )
    assert_nil get_medications_with_bundle(medications_bundle([ request ]), patient_id: "pt_001")
  end

  def test_get_conditions_returns_nil_when_other_patient_condition_would_be_excluded_as_refuted
    condition = build_condition_resource(
      subject: { "reference" => "Patient/pt_other" },
      verification_status: "refuted"
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]), patient_id: "pt_001")
  end

  def test_get_conditions_returns_nil_when_other_patient_condition_would_be_excluded_as_entered_in_error
    condition = build_condition_resource(
      subject: { "reference" => "Patient/pt_other" },
      verification_status: "entered-in-error"
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]), patient_id: "pt_001")
  end

  def test_get_conditions_returns_nil_when_other_patient_condition_would_be_excluded_by_out_of_scope_category
    condition = build_condition_resource(
      "id" => "cond_other_patient_oos",
      subject: { "reference" => "Patient/pt_other" },
      category: [ {
        "coding" => [ { "system" => US_CORE_CONDITION_CATEGORY_SYSTEM, "code" => "health-concern" } ]
      } ]
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]), patient_id: "pt_001")
  end

  # Coverage period partial dates (#640) -------------------------------------

  def coverage_bundle(period)
    {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => {
        "resourceType" => "Coverage",
        "id" => "cov_test_001",
        "status" => "cancelled",
        "type" => { "coding" => [ { "code" => "MCDSC" } ] },
        "period" => period
      } } ]
    }
  end

  def multi_type_coverage_bundle
    {
      "resourceType" => "Bundle",
      "entry" => [
        {
          "resource" => {
            "resourceType" => "Coverage",
            "id" => "cov_test_medicare",
            "status" => "active",
            "type" => { "coding" => [ { "code" => "MCRSC" } ] },
            "payor" => [ { "display" => "TEST MEDICARE PAYER" } ]
          }
        },
        {
          "resource" => {
            "resourceType" => "Coverage",
            "id" => "cov_test_medicaid",
            "status" => "active",
            "type" => { "coding" => [ { "code" => "MCDSC" } ] },
            "payor" => [ { "display" => "TEST MEDICAID PAYER" } ]
          }
        }
      ]
    }
  end

  def test_verify_eligibility_with_a_blank_resource_type_is_undetermined
    @adapter.stub(:fhir_search, multi_type_coverage_bundle) do
      [ nil, "", "   ", "\t \n", :"" ].each do |resource_type|
        assert_nil @adapter.verify_eligibility("pt_test_001", resource_type),
                   "resource_type #{resource_type.inspect} must not answer from arbitrary coverage"
      end

      assert_equal true, @adapter.verify_eligibility("pt_test_001", "medicaid")[:eligible]
      assert_equal true, @adapter.verify_eligibility("pt_test_001", "medicare_a")[:eligible]
    end
  end

  def eligibility_for_period(period)
    @adapter.stub(:fhir_search, coverage_bundle(period)) do
      @adapter.verify_eligibility("pt_test_001", "medicaid")
    end
  end

  def test_verify_eligibility_year_only_period_parses_to_year_range
    result = eligibility_for_period("start" => "2026", "end" => "2026")
    assert_equal Date.new(2026, 1, 1), result[:coverage_start]
    assert_equal Date.new(2026, 12, 31), result[:coverage_end]
  end

  def test_verify_eligibility_year_month_period_parses_to_month_range
    result = eligibility_for_period("start" => "2026-03", "end" => "2026-02")
    assert_equal Date.new(2026, 3, 1), result[:coverage_start]
    assert_equal Date.new(2026, 2, 28), result[:coverage_end]
  end

  def test_verify_eligibility_leap_february_period_end_is_last_day
    result = eligibility_for_period("end" => "2028-02")
    assert_nil result[:coverage_start]
    assert_equal Date.new(2028, 2, 29), result[:coverage_end]
  end

  def test_verify_eligibility_full_date_period_unchanged
    result = eligibility_for_period("start" => "2026-03-15", "end" => "2026-09-30T23:00:00Z")
    assert_equal Date.new(2026, 3, 15), result[:coverage_start]
    assert_equal Date.new(2026, 9, 30), result[:coverage_end]
  end

  def test_verify_eligibility_malformed_period_dates_stay_nil
    result = eligibility_for_period("start" => "2026-13", "end" => "not-a-date")
    assert_nil result[:coverage_start]
    assert_nil result[:coverage_end]
  end

  # Issue #712 R11 / R12: pick covering active Coverage; period bounds vs inquiry date.
  def test_verify_eligibility_prefers_active_coverage_covering_inquiry_over_ended_first_match
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [
        {
          "resource" => {
            "resourceType" => "Coverage",
            "id" => "cov_ended",
            "status" => "active",
            "type" => { "coding" => [ { "code" => "MCDSC" } ] },
            "payor" => [ { "display" => "ENDED PAYER" } ],
            "period" => { "start" => "2025-01-01", "end" => "2025-12-31" }
          }
        },
        {
          "resource" => {
            "resourceType" => "Coverage",
            "id" => "cov_active",
            "status" => "active",
            "type" => { "coding" => [ { "code" => "MCDSC" } ] },
            "payor" => [ { "display" => "ACTIVE PAYER 712" } ],
            "period" => { "start" => "2026-01-01", "end" => "2026-12-31" }
          }
        }
      ]
    }
    inquiry = Date.new(2026, 10, 15)

    @adapter.stub(:fhir_search, bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: inquiry)
      assert result[:eligible], "Must answer from coverage whose period covers the inquiry (issue #712 R11)"
      assert_equal "ACTIVE PAYER 712", result[:payer_name]
      assert_equal Date.new(2026, 1, 1), result[:coverage_start]
      assert_equal Date.new(2026, 12, 31), result[:coverage_end]
    end
  end

  def test_verify_eligibility_false_when_period_start_is_after_inquiry_date
    bundle = coverage_bundle("start" => "2026-11-01", "end" => "2026-12-31")
    bundle["entry"].first["resource"]["status"] = "active"

    @adapter.stub(:fhir_search, bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: Date.new(2026, 10, 15))
      refute result[:eligible]
    end
  end

  def test_verify_eligibility_false_when_period_end_is_before_inquiry_date
    bundle = coverage_bundle("start" => "2026-01-01", "end" => "2026-09-30")
    bundle["entry"].first["resource"]["status"] = "active"

    @adapter.stub(:fhir_search, bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: Date.new(2026, 10, 15))
      refute result[:eligible]
    end
  end

  # Issue #712 round 2: month-scoped active coverage vs full period bounds.
  def test_verify_eligibility_active_no_period_false_outside_current_month
    bundle = coverage_bundle({})
    bundle["entry"].first["resource"]["status"] = "active"
    inquiry = Date.new(2026, 12, 15)

    travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
      @adapter.stub(:fhir_search, bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: inquiry)
        refute result[:eligible], "Active coverage with no period must not cover a future-month inquiry (issue #712)"
        assert_equal inquiry, result[:date_of_service]
      end
    end
  end

  def test_verify_eligibility_active_no_period_true_in_current_month
    bundle = coverage_bundle({})
    bundle["entry"].first["resource"]["status"] = "active"
    inquiry = Date.new(2026, 10, 15)

    travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
      @adapter.stub(:fhir_search, bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: inquiry)
        assert result[:eligible], "Active coverage with no period must cover an inquiry in the current month (issue #712)"
        assert_equal inquiry, result[:date_of_service]
      end
    end
  end

  def test_verify_eligibility_active_start_only_false_for_future_month_inquiry
    bundle = coverage_bundle("start" => "2026-01-01")
    bundle["entry"].first["resource"]["status"] = "active"
    inquiry = Date.new(2026, 12, 15)

    travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
      @adapter.stub(:fhir_search, bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: inquiry)
        refute result[:eligible],
               "Start-only period must not make eligible outside the current month without an end bound (issue #712)"
        assert_equal inquiry, result[:date_of_service]
      end
    end
  end

  def test_verify_eligibility_active_full_period_true_for_inquiry_inside_bounds
    bundle = coverage_bundle("start" => "2026-01-01", "end" => "2026-12-31")
    bundle["entry"].first["resource"]["status"] = "active"
    inquiry = Date.new(2026, 12, 15)

    travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
      @adapter.stub(:fhir_search, bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: inquiry)
        assert result[:eligible], "Full period must cover an inquiry inside start and end (issue #712)"
        assert_equal inquiry, result[:date_of_service]
      end
    end
  end

  def test_verify_eligibility_active_no_period_false_for_past_month_inquiry
    bundle = coverage_bundle({})
    bundle["entry"].first["resource"]["status"] = "active"
    inquiry = Date.new(2025, 3, 1)

    travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
      @adapter.stub(:fhir_search, bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: inquiry)
        refute result[:eligible], "Active coverage with no period must not cover a past-month inquiry (issue #712)"
        assert_equal inquiry, result[:date_of_service]
      end
    end
  end

  def test_partial_birth_date_still_parses_to_nil
    resource = { "id" => "pt_test_001", "birthDate" => "1980", "name" => [ { "family" => "TEST", "given" => [ "PATIENT" ] } ] }
    @adapter.stub(:fhir_read, resource) do
      assert_nil @adapter.find_patient("pt_test_001").dob
    end
  end

  private

  TRIBAL_ENROLLMENT_EXTENSION_URL = "https://lakeraven.com/fhir/StructureDefinition/tribal-enrollment"

  def tribal_enrollment_patient(id, confidence_sub:)
    {
      "id" => id,
      "extension" => [ {
        "url" => TRIBAL_ENROLLMENT_EXTENSION_URL,
        "extension" => [
          { "url" => "enrolled", "valueBoolean" => true },
          { "url" => "tribeCode", "valueString" => "TGN" },
          { "url" => "confidence" }.merge(confidence_sub)
        ]
      } ]
    }
  end

  def no_content_http_response
    response = Net::HTTPNoContent.new("1.1", "204", "No Content")
    response.instance_variable_set(:@body, nil)
    response.instance_variable_set(:@read, true)
    response
  end

  def get_medications_with_bundle_without_extra_http(bundle, patient_id: "pt_001")
    http_calls = 0
    response = consumed_http_response(bundle)
    @adapter.stub(:http_get, ->(url) {
      http_calls += 1
      flunk("http_get must not read Medication when reference id is invalid") if url.include?("/Medication/")
      response
    }) do
      result = @adapter.get_medications(patient_id)
      assert_equal 1, http_calls
      result
    end
  end

  def clinical_read_with_http_fault(method, fault)
    @adapter.stub(:http_get, ->(_url) { raise fault }) { @adapter.public_send(method, "pt_001") }
  end

  # Raises from Net::HTTP#request so execute_http, http_get, and fhir_read all run.
  def with_transport_failure(error_class)
    requests = 0
    failing_http = Object.new
    failing_http.define_singleton_method(:request) do |_req|
      requests += 1
      raise error_class, "synthetic transport failure"
    end
    @adapter.stub(:build_http, failing_http) { yield }
    assert_equal 1, requests, "expected the Patient read to reach the transport"
  end

  def clinical_read_without_http(method, patient_identifier)
    http_calls = 0
    @adapter.stub(:http_get, ->(_url) { http_calls += 1; flunk("http_get must not run") }) do
      result = @adapter.public_send(method, patient_identifier)
      assert_equal 0, http_calls
      result
    end
  end

  def consumed_http_response(body, status: 200)
    json_body = body.is_a?(String) ? body : JSON.generate(body)
    response_class = Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPOK
    response = response_class.new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, json_body)
    response.instance_variable_set(:@read, true)
    response
  end

  def conditions_bundle(conditions, includes: [], type: "searchset", total: :omit)
    entries = conditions.map { |c| { "resource" => c, "search" => { "mode" => "match" } } }
    includes.each do |inc|
      resource, full_url = bundle_include_pair(inc)
      entry = { "resource" => resource, "search" => { "mode" => "include" } }
      entry["fullUrl"] = full_url if full_url
      entries << entry
    end
    bundle = { "resourceType" => "Bundle", "type" => type, "entry" => entries }
    bundle["total"] = total unless total == :omit
    bundle
  end

  def medications_bundle(requests, includes: [], type: "searchset", total: :omit)
    entries = requests.map { |r| { "resource" => r, "search" => { "mode" => "match" } } }
    includes.each do |inc|
      resource, full_url = bundle_include_pair(inc)
      entry = { "resource" => resource, "search" => { "mode" => "include" } }
      entry["fullUrl"] = full_url if full_url
      entries << entry
    end
    bundle = { "resourceType" => "Bundle", "type" => type, "entry" => entries }
    bundle["total"] = total unless total == :omit
    bundle
  end

  def bundle_include_pair(inc)
    return [ inc, nil ] unless inc.is_a?(Array)

    [ inc[0], inc[1] ]
  end

  def conditions_bundle_with_operation_outcome(conditions, issue_code:, severity:)
    entries = conditions.map { |c| { "resource" => c, "search" => { "mode" => "match" } } }
    entries << operation_outcome_bundle_entry(issue_code: issue_code, severity: severity)
    { "resourceType" => "Bundle", "type" => "searchset", "entry" => entries }
  end

  def medications_bundle_with_operation_outcome(requests, issue_code:, severity:)
    entries = requests.map { |r| { "resource" => r, "search" => { "mode" => "match" } } }
    entries << operation_outcome_bundle_entry(issue_code: issue_code, severity: severity)
    { "resourceType" => "Bundle", "type" => "searchset", "entry" => entries }
  end

  def operation_outcome_bundle_entry(issue_code:, severity:)
    {
      "resource" => {
        "resourceType" => "OperationOutcome",
        "issue" => [ { "severity" => severity, "code" => issue_code } ]
      }
    }
  end

  def searchset_bundle_with_links(bundle, links)
    bundle.merge("link" => links)
  end

  def positive_total_outcome_only_bundle(search_mode:)
    entry = operation_outcome_bundle_entry(issue_code: "informational", severity: "information")
    unless search_mode == :omit
      entry["search"] = { "mode" => search_mode }
    end
    { "resourceType" => "Bundle", "type" => "searchset", "total" => 1, "entry" => [ entry ] }
  end

  def us_core_category_element(variant)
    coding = { "system" => US_CORE_CONDITION_CATEGORY_SYSTEM }
    coding["code"] = category_code_for_variant(variant) unless variant == :missing
    { "coding" => [ coding ] }
  end

  def hl7_category_element(variant)
    coding = { "system" => CONDITION_CATEGORY_SYSTEM }
    coding["code"] = category_code_for_variant(variant) unless variant == :missing
    { "coding" => [ coding ] }
  end

  def category_code_for_variant(variant)
    case variant
    when :nil then nil
    when :blank then "   "
    else
      raise ArgumentError, "unknown category code variant: #{variant}"
    end
  end

  def build_condition_resource(overrides = {})
    overrides = overrides.deep_stringify_keys
    category_code = overrides.delete("category_code") || overrides.delete(:category_code) || "problem-list-item"
    clinical_status = overrides.delete("clinical_status") || overrides.delete(:clinical_status) || "active"
    clinical_status_system = overrides.delete("clinical_status_system") || overrides.delete(:clinical_status_system)
    clinical_status_codings = overrides.delete("clinical_status_codings") || overrides.delete(:clinical_status_codings)
    verification_status = overrides.delete("verification_status") || overrides.delete(:verification_status)
    verification_status_codings = overrides.delete("verification_status_codings") ||
                                    overrides.delete(:verification_status_codings)

    clinical_codings = if clinical_status_codings
      clinical_status_codings
    else
      coding = { "code" => clinical_status }
      coding["system"] = clinical_status_system if clinical_status_system
      [ coding ]
    end

    resource = {
      "resourceType" => "Condition",
      "id" => "cond_001",
      "subject" => { "reference" => "Patient/pt_001" },
      "category" => [ {
        "coding" => [ { "system" => CONDITION_CATEGORY_SYSTEM, "code" => category_code } ]
      } ],
      "clinicalStatus" => { "coding" => clinical_codings },
      "code" => {
        "coding" => [ { "system" => "http://example.test/codes", "code" => "C001", "display" => "TEST CONDITION 001" } ]
      },
      "onsetDateTime" => "2020-01-01"
    }

    if verification_status_codings
      resource["verificationStatus"] = { "coding" => verification_status_codings }
    elsif verification_status
      resource["verificationStatus"] = {
        "coding" => [ { "system" => CONDITION_VER_STATUS_SYSTEM, "code" => verification_status } ]
      }
    end

    resource.deep_merge(overrides)
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
      "type" => "searchset",
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
