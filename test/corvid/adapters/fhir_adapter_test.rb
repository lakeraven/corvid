# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "json"
require "zlib"
require "net/http"
require "uri"
require "net/protocol"
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


  # -- get_coverages (issue #607) ---------------------------------------------
  # Active-coverage date filtering uses Date.current in the adapter; stub both
  # Date.current and Date.today to FIXED_COVERAGE_TODAY for determinism.

  FIXED_COVERAGE_TODAY = Date.new(2026, 6, 15)

  def test_new_raises_argument_error_for_non_path_qualified_memory_base_url
    assert_raises(ArgumentError) do
      Corvid::Adapters::FhirAdapter.new(base_url: "memory://x")
    end
  end

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
    bundle = { "resourceType" => "Bundle", "type" => "searchset" }
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
    bundle = { "resourceType" => "Bundle", "type" => "searchset", "total" => 3 }
    with_stubbed_coverage_http({ coverage_search_url("pt_total_pos") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_total_pos")
    end
  end

  def test_get_coverages_returns_empty_array_when_total_zero_and_entry_absent
    bundle = { "resourceType" => "Bundle", "type" => "searchset", "total" => 0 }
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

  # N7 — only Bundle.link relation "next" is followed (#517 exact-relation rule).
  # "Next", "NEXT", and other case variants fail closed and must not fetch page 2.

  def test_get_coverages_returns_nil_when_next_link_relation_is_capitalized_next_without_fetching_page_two
    patient = "pt_next_case"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_nc1",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER NC1",
          type_code: "MCDSC",
          subscriber_id: "POL_NC1",
          period_start: Date.new(2026, 1, 1)
        )
      ],
      next_url: page2_url,
      next_relation: "Next"
    )
    page2_fetched = []
    with_stubbed_coverage_http({
      page1_url => http_ok_json(page1),
      page2_url => lambda {
        page2_fetched << true
        http_ok_json(coverage_bundle(entries: []))
      }
    }) do
      assert_nil @adapter.get_coverages(patient)
      assert_equal [ page1_url ], @requested_urls
      assert_empty page2_fetched
    end
  end

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

  MALFORMED_COVERAGE_OPERATION_OUTCOME_RESOURCE_CASES = [
    [ "issue key absent", ->(resource) { resource.delete("issue") } ],
    [ "issue is not an Array", ->(resource) { resource["issue"] = "not-an-array" } ],
    [ "issue contains a non-Hash element", ->(resource) { resource["issue"] = [ "not-a-hash" ] } ],
    [ "issue severity is capitalized Error", ->(resource) {
      resource["issue"] = [ { "severity" => "Error", "code" => "processing" } ]
    } ],
    [ "issue severity is nil", ->(resource) {
      resource["issue"] = [ { "severity" => nil, "code" => "processing" } ]
    } ],
    [ "issue severity is integer", ->(resource) {
      resource["issue"] = [ { "severity" => 5, "code" => "processing" } ]
    } ]
  ].freeze

  def test_get_coverages_returns_nil_for_malformed_operation_outcome_without_raising
    MALFORMED_COVERAGE_OPERATION_OUTCOME_RESOURCE_CASES.each do |label, mutate|
      resource = {
        "resourceType" => "OperationOutcome",
        "issue" => [ { "severity" => "warning", "code" => "informational" } ]
      }
      mutate.call(resource)
      bundle = coverage_bundle(entries: [ { "resource" => resource } ])
      with_stubbed_coverage_http({ coverage_search_url("pt_oo_malformed") => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages("pt_oo_malformed"),
                   "expected nil for malformed OperationOutcome: #{label}"
      end
    end
  end

  COVERAGE_UNTRUSTED_OUTCOME_CODES = %w[
    suppressed incomplete too-costly timeout throttled too-long exception
  ].freeze

  COVERAGE_UNTRUSTED_OUTCOME_SEVERITIES = %w[fatal error warning information].freeze

  INEXACT_COVERAGE_UNTRUSTED_OUTCOME_CODES = [
    "Suppressed",
    "incomplete ",
    " TOO-COSTLY",
    "Timeout"
  ].freeze

  UNICODE_COVERAGE_UNTRUSTED_OUTCOME_CODES = [
    "incomplete\u00A0",
    "\u2003timeout",
    "throttled\u200B",
    "too-long\u3000",
    "\uFEFFsuppressed"
  ].freeze

  def test_get_coverages_returns_nil_when_operation_outcome_has_untrusted_code_at_warning_or_information_severity
    coverage = coverage_fhir_resource(
      id: "cov_untrusted_oo",
      for_patient: "pt_oo_untrusted",
      status: "active",
      payer_display: "TEST PAYER UNTRUSTED OO",
      type_code: "MCDSC",
      subscriber_id: "POL_UOO",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    COVERAGE_UNTRUSTED_OUTCOME_CODES.each do |code|
      COVERAGE_UNTRUSTED_OUTCOME_SEVERITIES.each do |severity|
        bundle = coverage_bundle(
          entries: [
            {
              "resource" => {
                "resourceType" => "OperationOutcome",
                "issue" => [ { "severity" => severity, "code" => code, "diagnostics" => "TEST" } ]
              }
            },
            coverage
          ]
        )
        with_stubbed_coverage_http({ coverage_search_url("pt_oo_untrusted") => http_ok_json(bundle) }) do
          assert_nil @adapter.get_coverages("pt_oo_untrusted"),
                     "expected nil for OperationOutcome #{severity}/#{code} with active Coverage"
        end
      end
    end
  end

  def test_get_coverages_returns_nil_when_operation_outcome_has_inexact_untrusted_code_at_any_severity
    coverage = coverage_fhir_resource(
      id: "cov_inexact_oo",
      for_patient: "pt_oo_inexact",
      status: "active",
      payer_display: "TEST PAYER INEXACT OO",
      type_code: "MCDSC",
      subscriber_id: "POL_INEX",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    INEXACT_COVERAGE_UNTRUSTED_OUTCOME_CODES.each do |code|
      COVERAGE_UNTRUSTED_OUTCOME_SEVERITIES.each do |severity|
        bundle = coverage_bundle(
          entries: [
            {
              "resource" => {
                "resourceType" => "OperationOutcome",
                "issue" => [ { "severity" => severity, "code" => code } ]
              }
            },
            coverage
          ]
        )
        with_stubbed_coverage_http({ coverage_search_url("pt_oo_inexact") => http_ok_json(bundle) }) do
          assert_nil @adapter.get_coverages("pt_oo_inexact"),
                     "expected nil for malformed or untrusted OperationOutcome #{severity}/#{code.inspect}"
        end
      end
    end
  end

  def test_get_coverages_returns_nil_when_operation_outcome_has_unicode_whitespace_untrusted_code_at_any_severity
    coverage = coverage_fhir_resource(
      id: "cov_unicode_oo",
      for_patient: "pt_oo_unicode",
      status: "active",
      payer_display: "TEST PAYER UNICODE OO",
      type_code: "MCDSC",
      subscriber_id: "POL_UOO",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    UNICODE_COVERAGE_UNTRUSTED_OUTCOME_CODES.each do |code|
      COVERAGE_UNTRUSTED_OUTCOME_SEVERITIES.each do |severity|
        bundle = coverage_bundle(
          entries: [
            {
              "resource" => {
                "resourceType" => "OperationOutcome",
                "issue" => [ { "severity" => severity, "code" => code } ]
              }
            },
            coverage
          ]
        )
        with_stubbed_coverage_http({ coverage_search_url("pt_oo_unicode") => http_ok_json(bundle) }) do
          assert_nil @adapter.get_coverages("pt_oo_unicode"),
                     "expected nil for malformed (non-ASCII-token) OperationOutcome #{severity}/#{code.inspect}"
        end
      end
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
  PHDSC_SOP_SYSTEM_NAHDO = "https://nahdo.org/sopt"
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

  # G1 — PHDSC SOP on HL7 THO canonical URL https://nahdo.org/sopt (issue #607)

  ISSUE_607_SOP_EXCLUDED_ON_NAHDO = %w[333 81 82 95].freeze
  ISSUE_607_SOP_INCLUDED_ON_NAHDO = %w[511 21].freeze

  def test_get_coverages_excludes_active_coverage_for_phscd_sop_non_insurer_on_nahdo_sopt_system
    ISSUE_607_SOP_EXCLUDED_ON_NAHDO.each do |sop_code|
      patient_id = "pt_g1_exc_#{sop_code}"
      resource = issue_607_organization_coverage(
        id: "cov_g1_exc_#{sop_code}",
        for_patient: patient_id,
        type_codings: [ { "system" => PHDSC_SOP_SYSTEM_NAHDO, "code" => sop_code } ]
      )
      assert_single_excluded_issue_607_coverage(
        patient_id, resource,
        "PHDSC SOP #{sop_code.inspect} on #{PHDSC_SOP_SYSTEM_NAHDO}"
      )
    end
  end

  def test_get_coverages_includes_active_coverage_for_phscd_sop_insurer_family_on_nahdo_sopt_system
    ISSUE_607_SOP_INCLUDED_ON_NAHDO.each do |sop_code|
      patient_id = "pt_g1_inc_#{sop_code}"
      resource = issue_607_organization_coverage(
        id: "cov_g1_inc_#{sop_code}",
        for_patient: patient_id,
        type_codings: [ { "system" => PHDSC_SOP_SYSTEM_NAHDO, "code" => sop_code } ]
      )
      assert_single_included_issue_607_coverage(
        patient_id, resource,
        "PHDSC SOP #{sop_code.inspect} on #{PHDSC_SOP_SYSTEM_NAHDO}"
      )
    end
  end

  # G2 — type.text self-pay normalisation (issue #607)

  ISSUE_607_SELF_PAY_TYPE_TEXT_EXCLUDED = [
    "Self-Pay",
    "SELFPAY",
    "self  pay",
    " Self pay "
  ].freeze

  def test_get_coverages_excludes_active_coverage_when_type_text_normalises_to_self_pay_without_coding
    ISSUE_607_SELF_PAY_TYPE_TEXT_EXCLUDED.each do |label|
      patient_id = "pt_g2_text_#{label.gsub(/\s+/, '_').tr('-', '_').downcase}"
      resource = issue_607_organization_coverage(
        id: "cov_g2_text",
        for_patient: patient_id,
        type_text: label
      )
      assert_single_excluded_issue_607_coverage(
        patient_id, resource,
        "type.text #{label.inspect} without coding (normalised self-pay)"
      )
    end
  end

  def test_get_coverages_includes_active_coverage_when_type_text_is_self_pay_plus_insurance_without_coding
    resource = issue_607_organization_coverage(
      id: "cov_g2_plus",
      for_patient: "pt_g2_plus",
      type_text: "Self Pay Plus Insurance"
    )
    assert_single_included_issue_607_coverage(
      "pt_g2_plus", resource,
      "type.text Self Pay Plus Insurance is not exact normalised self-pay"
    )
  end

  # G3 — X12 claim-filing-indicator code 9 vs 09 (issue #607)

  def test_get_coverages_excludes_active_coverage_with_x12_claim_filing_indicator_9_string_with_system
    resource = issue_607_organization_coverage(
      id: "cov_g3_x12_9_str",
      for_patient: "pt_g3_x12_9_str",
      type_codings: [ { "system" => X12_CLAIM_FILING_INDICATOR_SYSTEM, "code" => "9" } ]
    )
    assert_single_excluded_issue_607_coverage(
      "pt_g3_x12_9_str", resource,
      "X12 9 (string) with claim-filing-indicator system"
    )
  end

  def test_get_coverages_excludes_active_coverage_with_x12_claim_filing_indicator_9_number_with_system
    resource = issue_607_organization_coverage(
      id: "cov_g3_x12_9_num",
      for_patient: "pt_g3_x12_9_num",
      type_codings: [ { "system" => X12_CLAIM_FILING_INDICATOR_SYSTEM, "code" => 9 } ]
    )
    assert_single_excluded_issue_607_coverage(
      "pt_g3_x12_9_num", resource,
      "X12 9 (JSON number) with claim-filing-indicator system"
    )
  end

  def test_get_coverages_includes_active_coverage_with_bare_x12_code_9_without_system
    resource = issue_607_organization_coverage(
      id: "cov_g3_bare_9",
      for_patient: "pt_g3_bare_9",
      type_codings: [ { "code" => "9" } ]
    )
    assert_single_included_issue_607_coverage(
      "pt_g3_bare_9", resource,
      "bare code 9 without system is not self-pay (only bare 09 is)"
    )
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

  # Chair round — invalid UTF-8 in Coverage strings must fail closed (nil), never raise

  def test_get_coverages_returns_nil_for_invalid_utf8_in_coverage_string_fields_without_raising
    patient = "pt_u8_fields"
    invalid = invalid_utf8_byte_sequence
    cases = [
      [
        "type coding code",
        { type_json: %({"coding":[{"system":"#{PHDSC_SOP_SYSTEM}","code":"2) + invalid + %("}]}) }
      ],
      [
        "payor reference",
        { payor_json: %([{"reference":"Organization/org) + invalid + %(","display":"TEST PAYER"}]) }
      ],
      [
        "period.start",
        { period_json: %({"start":"2026-01-01) + invalid + %(","end":"2026-12-31"}) }
      ],
      [
        "period.end",
        { period_json: %({"start":"2026-01-01","end":"2026-12-31) + invalid + %("}) }
      ],
      [
        "type.text",
        { type_json: %({"text":"plan) + invalid + %("}) }
      ],
      [
        "type coding system",
        { type_json: %({"coding":[{"system":"http://test.local/x) + invalid + %(","code":"EHCPOL"}]}) }
      ]
    ]
    cases.each do |label, fragments|
      body = issue_607_coverage_bundle_http_body(patient_id: patient, **fragments)
      with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_body(body) }) do
        coverage_error = nil
        result = nil
        begin
          result = @adapter.get_coverages(patient)
        rescue ArgumentError => e
          coverage_error = e
        end
        if coverage_error
          flunk "expected get_coverages not to raise for invalid UTF-8 in #{label}, " \
                "got #{coverage_error.class}: #{coverage_error.message}"
        end
        assert_nil result, "expected nil for invalid UTF-8 in #{label}"
      end
    end
  end

  def test_get_coverages_returns_nil_when_payor_display_subscriber_id_or_type_code_present_but_not_string
    patient = "pt_oo_typed_strings"
    non_string_cases = [
      [
        "payor display is integer",
        { payor_json: '[{"reference":"Organization/org1","display":42}]' }
      ],
      [
        "payor display is Hash",
        { payor_json: '[{"reference":"Organization/org1","display":{"text":"TEST"}}]' }
      ],
      [
        "payor display is Array",
        { payor_json: '[{"reference":"Organization/org1","display":["TEST"]}]' }
      ],
      [
        "subscriberId is integer",
        { subscriber_id_json: "42" }
      ],
      [
        "subscriberId is Hash",
        { subscriber_id_json: '{"id":"POL"}' }
      ],
      [
        "subscriberId is Array",
        { subscriber_id_json: '["POL"]' }
      ],
      [
        "type coding code is integer",
        { type_json: '{"coding":[{"code":2}]}' }
      ],
      [
        "type coding code is Hash",
        { type_json: '{"coding":[{"code":{"value":"EHCPOL"}}]}' }
      ],
      [
        "type coding code is Array",
        { type_json: '{"coding":[{"code":["EHCPOL"]}]}' }
      ]
    ]
    non_string_cases.each do |label, fragments|
      body = issue_607_coverage_bundle_http_body(patient_id: patient, **fragments)
      with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_body(body) }) do
        assert_nil @adapter.get_coverages(patient), "expected nil when #{label}"
      end
    end
  end

  def test_get_coverages_returns_nil_when_response_body_is_not_valid_utf8_without_raising
    patient = "pt_u8_body"
    valid_body = issue_607_coverage_bundle_http_body(patient_id: patient)
    body = valid_body.b + invalid_utf8_byte_sequence
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_body(body) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  # Chair round — paginated Bundle.total consistency across pages

  def test_get_coverages_returns_both_coverages_when_trailing_page_has_no_entry_but_repeats_total
    patient = "pt_pag_trail_empty"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_trail1",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER TRAIL1",
          type_code: "MCDSC",
          subscriber_id: "POL_TR1",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        ),
        coverage_fhir_resource(
          id: "cov_trail2",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER TRAIL2",
          type_code: "EHCPOL",
          subscriber_id: "POL_TR2",
          period_start: Date.new(2026, 2, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 2,
      next_url: page2_url
    )
    page2 = { "resourceType" => "Bundle", "type" => "searchset", "total" => 2 }
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      result = @adapter.get_coverages(patient)
      assert_equal 2, result.size
      assert_equal [ page1_url, page2_url ], @requested_urls
    end
  end

  def test_get_coverages_returns_nil_when_later_page_total_differs_from_first_page_total
    patient = "pt_pag_total_mismatch"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_mis1",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER MIS1",
          type_code: "MCDSC",
          subscriber_id: "POL_MIS1",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 2,
      next_url: page2_url
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_mis2",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER MIS2",
          type_code: "EHCPOL",
          subscriber_id: "POL_MIS2",
          period_start: Date.new(2026, 2, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 3
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_both_when_later_page_omits_total_and_running_count_matches_first_page_total
    patient = "pt_pag_no_total_page2"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_nt1",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER NT1",
          type_code: "MCDSC",
          subscriber_id: "POL_NT1",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 2,
      next_url: page2_url
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_nt2",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER NT2",
          type_code: "EHCPOL",
          subscriber_id: "POL_NT2",
          period_start: Date.new(2026, 2, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      result = @adapter.get_coverages(patient)
      assert_equal 2, result.size
      assert_equal [ page1_url, page2_url ], @requested_urls
    end
  end

  # Chair round 2 — duplicate Coverage ids, link shape, entry shape, Bundle.type

  def test_get_coverages_returns_nil_when_same_coverage_id_appears_twice_on_one_page
    patient = "pt_dup_same_page"
    shared = coverage_fhir_resource(
      id: "cov_dup_a",
      for_patient: patient,
      status: "active",
      payer_display: "TEST PAYER DUP1",
      type_code: "MCDSC",
      subscriber_id: "POL_DUP1",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    other = coverage_fhir_resource(
      id: "cov_dup_a",
      for_patient: patient,
      status: "active",
      payer_display: "TEST PAYER DUP2",
      type_code: "EHCPOL",
      subscriber_id: "POL_DUP2",
      period_start: Date.new(2026, 2, 1),
      period_end: Date.new(2026, 12, 31)
    )
    bundle = coverage_bundle(entries: [ shared, other ], total: 2)
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_same_coverage_id_appears_on_two_pages
    patient = "pt_dup_two_pages"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_dup_x",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER DUP P1",
          type_code: "MCDSC",
          subscriber_id: "POL_DUP_P1",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 2,
      next_url: page2_url
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_dup_x",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER DUP P2",
          type_code: "EHCPOL",
          subscriber_id: "POL_DUP_P2",
          period_start: Date.new(2026, 2, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 2
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_paginated_bundle_repeats_same_coverage_id_across_pages
    patient = "pt_dup_offset"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    repeated = coverage_fhir_resource(
      id: "cov_offset_dup",
      for_patient: patient,
      status: "active",
      payer_display: "TEST PAYER OFFSET",
      type_code: "MCDSC",
      subscriber_id: "POL_OFF",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    page1 = coverage_bundle(entries: [ repeated ], total: 2, next_url: page2_url)
    page2 = coverage_bundle(entries: [ repeated ], total: 2)
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_one_page_lists_same_coverage_id_twice_both_cancelled
    patient = "pt_dup_cancelled"
    cancelled = coverage_fhir_resource(
      id: "cov_dup_can",
      for_patient: patient,
      status: "cancelled",
      payer_display: "TEST PAYER CAN",
      type_code: "MCDSC",
      subscriber_id: "POL_CAN",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    bundle = coverage_bundle(entries: [ cancelled, cancelled.dup ], total: 2)
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_coverage_resource_id_is_empty_string
    patient = "pt_cov_id_empty"
    resource = coverage_fhir_resource(
      id: "",
      for_patient: patient,
      status: "active",
      payer_display: "TEST PAYER ID EMPTY",
      type_code: "MCDSC",
      subscriber_id: "POL_IDE",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    bundle = coverage_bundle_total_one(resource)
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_coverage_resource_id_is_missing
    patient = "pt_cov_id_missing"
    resource = coverage_fhir_resource(
      id: "cov_drop_id",
      for_patient: patient,
      status: "active",
      payer_display: "TEST PAYER ID MISS",
      type_code: "MCDSC",
      subscriber_id: "POL_IDM",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    resource.delete("id")
    bundle = coverage_bundle_total_one(resource)
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_next_link_relation_is_next_only_after_strip
    patient = "pt_link_next_space"
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_lns",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER LNS",
          type_code: "MCDSC",
          subscriber_id: "POL_LNS",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      next_url: page2_url,
      next_relation: "next "
    )
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_next_link_relation_is_uppercase_next
    patient = "pt_link_next_upper"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_lnu1",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER LNU1",
          type_code: "MCDSC",
          subscriber_id: "POL_LNU1",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 2,
      next_url: page2_url,
      next_relation: "NEXT"
    )
    page2 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_lnu2",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER LNU2",
          type_code: "EHCPOL",
          subscriber_id: "POL_LNU2",
          period_start: Date.new(2026, 2, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      total: 2
    )
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_link_relation_is_an_array
    patient = "pt_link_rel_array"
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_lra",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER LRA",
          type_code: "MCDSC",
          subscriber_id: "POL_LRA",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    bundle["link"] = [ { "relation" => [ "next" ], "url" => page2_url } ]
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_bundle_has_more_than_one_next_link
    patient = "pt_link_two_next"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_l2n",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER L2N",
          type_code: "MCDSC",
          subscriber_id: "POL_L2N",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    page1["link"] = [
      { "relation" => "next", "url" => page2_url },
      { "relation" => "next", "url" => page2_url }
    ]
    page2 = coverage_bundle(entries: [])
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_bundle_link_is_not_an_array
    patient = "pt_link_not_array"
    bundle = coverage_bundle_total_one(
      coverage_fhir_resource(
        id: "cov_lna",
        for_patient: patient,
        status: "active",
        payer_display: "TEST PAYER LNA",
        type_code: "MCDSC",
        subscriber_id: "POL_LNA",
        period_start: Date.new(2026, 1, 1),
        period_end: Date.new(2026, 12, 31)
      )
    )
    bundle["link"] = { "relation" => "self", "url" => coverage_search_url(patient) }
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_link_entry_is_not_a_hash
    patient = "pt_link_bad_entry"
    bundle = coverage_bundle_total_one(
      coverage_fhir_resource(
        id: "cov_lbe",
        for_patient: patient,
        status: "active",
        payer_display: "TEST PAYER LBE",
        type_code: "MCDSC",
        subscriber_id: "POL_LBE",
        period_start: Date.new(2026, 1, 1),
        period_end: Date.new(2026, 12, 31)
      )
    )
    bundle["link"] = [
      { "relation" => "self", "url" => coverage_search_url(patient) },
      "not-a-link-hash"
    ]
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_next_link_url_is_not_a_string
    patient = "pt_link_url_int"
    bundle = coverage_bundle_total_one(
      coverage_fhir_resource(
        id: "cov_lui",
        for_patient: patient,
        status: "active",
        payer_display: "TEST PAYER LUI",
        type_code: "MCDSC",
        subscriber_id: "POL_LUI",
        period_start: Date.new(2026, 1, 1),
        period_end: Date.new(2026, 12, 31)
      )
    )
    bundle["link"] = [ { "relation" => "next", "url" => 42 } ]
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_bundle_entry_is_not_a_hash
    patient = "pt_entry_not_hash"
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_enh",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER ENH",
          type_code: "MCDSC",
          subscriber_id: "POL_ENH",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    bundle["entry"] << "not-an-entry"
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_bundle_entry_has_no_resource_hash
    patient = "pt_entry_no_res"
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_enr",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER ENR",
          type_code: "MCDSC",
          subscriber_id: "POL_ENR",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ]
    )
    bundle["entry"] << { "fullUrl" => "urn:uuid:no-resource" }
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_entry_resource_lacks_string_resource_type
    patient = "pt_entry_no_rt"
    bundle = coverage_bundle(
      entries: [
        {
          "resource" => {
            "id" => "cov_nort",
            "status" => "active",
            "beneficiary" => { "reference" => "Patient/#{patient}" },
            "payor" => [ { "reference" => "Organization/org1", "display" => "TEST" } ],
            "type" => { "coding" => [ { "code" => "MCDSC" } ] },
            "period" => { "start" => "2026-01-01", "end" => "2026-12-31" }
          }
        }
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_coverage_resource_type_is_lowercase_not_exact
    patient = "pt_rt_lower"
    resource = coverage_fhir_resource(
      id: "cov_lower_rt",
      for_patient: patient,
      status: "active",
      payer_display: "TEST PAYER LRT",
      type_code: "MCDSC",
      subscriber_id: "POL_LRT",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    resource["resourceType"] = "coverage"
    bundle = coverage_bundle(entries: [ resource ])
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_bundle_type_is_history
    patient = "pt_bundle_history"
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_hist",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER HIST",
          type_code: "MCDSC",
          subscriber_id: "POL_HIST",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      bundle_type: "history"
    )
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_bundle_type_is_collection
    patient = "pt_bundle_collection"
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_coll",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER COLL",
          type_code: "MCDSC",
          subscriber_id: "POL_COLL",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      bundle_type: "collection"
    )
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  def test_get_coverages_returns_nil_when_bundle_type_is_missing
    patient = "pt_bundle_no_type"
    bundle = coverage_bundle(
      entries: [
        coverage_fhir_resource(
          id: "cov_notype",
          for_patient: patient,
          status: "active",
          payer_display: "TEST PAYER NOTYPE",
          type_code: "MCDSC",
          subscriber_id: "POL_NT",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )
      ],
      bundle_type: nil
    )
    bundle.delete("type")
    with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages(patient)
    end
  end

  # Round 2 chair decisions (#607) — each must fail until get_coverages matches clinical reads.

  def test_get_coverages_returns_nil_for_nil_patient_identifier_without_http
    assert_nil clinical_read_without_http(:get_coverages, nil)
  end

  def test_get_coverages_returns_nil_for_blank_patient_identifier_without_http
    assert_nil clinical_read_without_http(:get_coverages, "")
  end

  def test_get_coverages_returns_nil_for_whitespace_only_patient_identifier_without_http
    assert_nil clinical_read_without_http(:get_coverages, "   \t")
  end

  def test_get_coverages_returns_nil_when_bundle_has_unexpected_resource_without_include_mode
    coverage = coverage_fhir_resource(
      id: "cov_unexp",
      for_patient: "pt_unexp",
      status: "active",
      payer_display: "TEST PAYER UNEXP",
      type_code: "MCDSC",
      subscriber_id: "POL_UNEXP",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
    bundle = coverage_bundle(
      entries: [
        coverage,
        { "resource" => { "resourceType" => "Provenance", "id" => "prov_1" } }
      ],
      total: 1
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_unexp") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_unexp")
    end
  end

  INEXACT_COVERAGE_OPERATION_OUTCOME_RESOURCE_TYPES = [
    "operationOutcome",
    "OperationOutcome "
  ].freeze

  def test_get_coverages_returns_nil_when_operation_outcome_resource_type_is_not_exact
    INEXACT_COVERAGE_OPERATION_OUTCOME_RESOURCE_TYPES.each do |resource_type|
      bundle = coverage_bundle(
        entries: [
          {
            "resource" => {
              "resourceType" => resource_type,
              "issue" => [ { "severity" => "warning", "code" => "informational" } ]
            }
          }
        ]
      )
      with_stubbed_coverage_http({ coverage_search_url("pt_oo_rt") => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages("pt_oo_rt"),
                   "expected nil for inexact OperationOutcome resourceType #{resource_type.inspect}"
      end
    end
  end

  def test_get_coverages_returns_nil_when_operation_outcome_has_empty_issue_array
    bundle = coverage_bundle(
      entries: [
        { "resource" => { "resourceType" => "OperationOutcome", "issue" => [] } }
      ]
    )
    with_stubbed_coverage_http({ coverage_search_url("pt_oo_empty") => http_ok_json(bundle) }) do
      assert_nil @adapter.get_coverages("pt_oo_empty")
    end
  end

  def test_get_coverages_returns_nil_when_operation_outcome_issue_code_is_not_a_string
    non_string_codes = [ 5, [ "incomplete" ], { "value" => "incomplete" } ]
    non_string_codes.each do |code|
      bundle = coverage_bundle(
        entries: [
          {
            "resource" => {
              "resourceType" => "OperationOutcome",
              "issue" => [ { "severity" => "warning", "code" => code } ]
            }
          }
        ]
      )
      with_stubbed_coverage_http({ coverage_search_url("pt_oo_code") => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages("pt_oo_code"),
                   "expected nil when OperationOutcome issue code is #{code.inspect}"
      end
    end
  end

  UNICODE_NEXT_COVERAGE_LINK_RELATIONS = [
    "next\u00A0",
    "next\u2003"
  ].freeze

  def test_get_coverages_returns_nil_when_next_link_relation_equals_next_only_after_unicode_whitespace
    UNICODE_NEXT_COVERAGE_LINK_RELATIONS.each do |next_relation|
      patient = "pt_link_unicode_#{next_relation.bytes.join('_')}"
      page1_url = coverage_search_url(patient)
      page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
      page1 = coverage_bundle(
        entries: [
          coverage_fhir_resource(
            id: "cov_unicode",
            for_patient: patient,
            status: "active",
            payer_display: "TEST PAYER UNICODE",
            type_code: "MCDSC",
            subscriber_id: "POL_UNICODE",
            period_start: Date.new(2026, 1, 1),
            period_end: Date.new(2026, 12, 31)
          )
        ],
        total: 1,
        next_url: page2_url,
        next_relation: next_relation
      )
      page2_fetched = []
      with_stubbed_coverage_http({
        page1_url => http_ok_json(page1),
        page2_url => lambda {
          page2_fetched << true
          http_ok_json(coverage_bundle(entries: []))
        }
      }) do
        assert_nil @adapter.get_coverages(patient),
                   "expected nil for next link relation #{next_relation.inspect}"
        assert_equal [ page1_url ], @requested_urls
        assert_empty page2_fetched
      end
    end
  end

  FORMAT_CHARACTER_NEXT_LINK_RELATIONS = [
    [ "zwsp_suffix", "next\u200B" ],
    [ "bom_prefix", "\uFEFFnext" ],
    [ "zwj_suffix", "next\u200D" ],
    [ "soft_hyphen", "nex\u00ADt" ]
  ].freeze

  def test_get_coverages_returns_nil_when_next_link_relation_contains_format_characters
    FORMAT_CHARACTER_NEXT_LINK_RELATIONS.each do |label, next_relation|
      patient = "pt_link_fmt_#{label}"
      page1_url = coverage_search_url(patient)
      page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
      page1 = coverage_bundle(
        entries: [ parity_coverage_resource(patient, "fmt") ],
        next_url: page2_url,
        next_relation: next_relation
      )
      page2_fetched = []
      with_stubbed_coverage_http({
        page1_url => http_ok_json(page1),
        page2_url => lambda {
          page2_fetched << true
          http_ok_json(coverage_bundle(entries: []))
        }
      }) do
        assert_nil @adapter.get_coverages(patient),
                   "expected nil for next link relation with format chars (#{label})"
        assert_equal [ page1_url ], @requested_urls
        assert_empty page2_fetched
      end
    end
  end

  def test_get_coverages_returns_nil_when_next_link_relation_contains_format_characters_without_bundle_total
    label, next_relation = FORMAT_CHARACTER_NEXT_LINK_RELATIONS.first
    patient = "pt_link_fmt_nototal_#{label}"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [ parity_coverage_resource(patient, "fmtnt") ],
      next_url: page2_url,
      next_relation: next_relation
    )
    page1.delete("total")
    with_stubbed_coverage_http({ page1_url => http_ok_json(page1) }) do
      result = @adapter.get_coverages(patient)
      assert_nil result, "expected nil without total when relation has format characters"
      assert_equal [ page1_url ], @requested_urls
    end
  end

  MALFORMED_COVERAGE_KIND_VALUES = [
    [ "miscased_insurance", "Insurance" ],
    [ "explicit_json_null", nil ],
    [ "integer_kind", 1 ],
    [ "padded_insurance", "insurance " ]
  ].freeze

  def test_get_coverages_returns_nil_for_malformed_coverage_kind
    MALFORMED_COVERAGE_KIND_VALUES.each do |label, kind_value|
      patient = "pt_kind_#{label}"
      resource = issue_607_organization_coverage(
        id: "cov_kind_#{label}",
        for_patient: patient,
        type_code: "EHCPOL"
      )
      resource["kind"] = kind_value
      bundle = coverage_bundle_total_one(resource)
      with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
        assert_nil @adapter.get_coverages(patient),
                   "expected nil for malformed Coverage.kind #{label.inspect}, not empty allowlist miss"
      end
    end
  end

  def test_get_coverages_keeps_today_behaviour_for_absent_or_exact_insurance_kind
    patient_absent = "pt_kind_absent"
    resource_absent = issue_607_organization_coverage(
      id: "cov_kind_absent",
      for_patient: patient_absent,
      type_code: "EHCPOL"
    )
    assert_single_included_issue_607_coverage(patient_absent, resource_absent, "absent kind")

    patient_exact = "pt_kind_exact"
    resource_exact = issue_607_organization_coverage(
      id: "cov_kind_exact",
      for_patient: patient_exact,
      type_code: "EHCPOL"
    )
    resource_exact["kind"] = "insurance"
    assert_single_included_issue_607_coverage(patient_exact, resource_exact, "exact insurance kind")
  end

  SECONDARY_NON_STRING_TYPE_CODES = [ 51, { "value" => "EHCPOL" } ].freeze

  def test_get_coverages_returns_nil_when_secondary_type_coding_code_is_not_string
    SECONDARY_NON_STRING_TYPE_CODES.each do |bad_code|
      patient = "pt_type_sec_#{bad_code.hash.abs}"
      resource = issue_607_organization_coverage(
        id: "cov_type_sec",
        for_patient: patient,
        type_codings: [
          { "code" => "EHCPOL" },
          { "code" => bad_code }
        ]
      )
      bundle = coverage_bundle_total_one(resource)
      with_stubbed_coverage_http({ coverage_search_url(patient) => http_ok_json(bundle) }) do
        result = @adapter.get_coverages(patient)
        assert_nil result,
                   "expected nil when secondary type.coding code is #{bad_code.inspect}, not []"
      end
    end
  end

  def test_get_coverages_and_fhir_search_coverage_parity_reject_unsafe_next_links
    rejected_next_link_parity_cases.each do |case_name, build_case|
      build_case.call(self, case_name)
    end
  end

  def test_get_coverages_and_fhir_search_coverage_parity_follow_accepted_next_links
    patient = "pt_parity_ok"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [ parity_coverage_resource(patient, "p1") ],
      total: 2,
      next_url: "Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    )
    page2 = coverage_bundle(
      entries: [ parity_coverage_resource(patient, "p2", type_code: "EHCPOL") ],
      total: 2
    )
    responses = { page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) }
    with_stubbed_coverage_http(responses) do
      coverages = @adapter.get_coverages(patient)
      refute_nil coverages, "get_coverages should follow exact relative next"
      assert_equal 2, coverages.size
      assert_equal [ page1_url, page2_url ], @requested_urls
    end
    with_stubbed_coverage_http(responses) do
      bundle = @adapter.send(:fhir_search, "Coverage", beneficiary: "Patient/#{patient}")
      refute_nil bundle, "fhir_search should follow exact relative next"
      assert_equal 2, bundle["entry"].size
      assert_equal [ page1_url, page2_url ], @requested_urls
    end
  end

  UNICODE_TRUST_DEFEATING_OUTCOME_CODES = [
    "incomplete\u00A0",
    "\u2003timeout",
    "throttled\u200B",
    "too-long\u3000",
    "\uFEFFsuppressed"
  ].freeze

  CLINICAL_OPERATION_OUTCOME_NON_STRING_CODES = [
    5,
    [ "incomplete" ],
    { "code" => "incomplete" }
  ].freeze

  def test_get_conditions_returns_nil_when_operation_outcome_issue_code_is_not_a_string
    condition = build_condition_resource
    CLINICAL_OPERATION_OUTCOME_NON_STRING_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = conditions_bundle_with_operation_outcome([ condition ], issue_code: code, severity: severity)
        assert_nil get_conditions_with_bundle(bundle),
                   "expected nil when Condition OperationOutcome issue code is #{code.inspect} at #{severity}"
      end
    end
  end

  def test_get_medications_returns_nil_when_operation_outcome_issue_code_is_not_a_string
    request = build_medication_request_resource
    CLINICAL_OPERATION_OUTCOME_NON_STRING_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = medications_bundle_with_operation_outcome([ request ], issue_code: code, severity: severity)
        assert_nil get_medications_with_bundle(bundle),
                   "expected nil when MedicationRequest OperationOutcome issue code is #{code.inspect} at #{severity}"
      end
    end
  end

  def test_get_conditions_returns_nil_when_operation_outcome_has_unicode_whitespace_untrusted_code_at_any_severity
    condition = build_condition_resource
    UNICODE_TRUST_DEFEATING_OUTCOME_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = conditions_bundle_with_operation_outcome([ condition ], issue_code: code, severity: severity)
        assert_nil get_conditions_with_bundle(bundle),
                   "expected nil for malformed (non-ASCII-token) OperationOutcome #{severity}/#{code.inspect} on Condition search"
      end
    end
  end

  def test_get_medications_returns_nil_when_operation_outcome_has_unicode_whitespace_untrusted_code_at_any_severity
    request = build_medication_request_resource
    UNICODE_TRUST_DEFEATING_OUTCOME_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = medications_bundle_with_operation_outcome([ request ], issue_code: code, severity: severity)
        assert_nil get_medications_with_bundle(bundle),
                   "expected nil for malformed (non-ASCII-token) OperationOutcome #{severity}/#{code.inspect} on MedicationRequest search"
      end
    end
  end

  private

  def invalid_utf8_byte_sequence
    "\xFF".b.force_encoding(Encoding::UTF_8)
  end

  def issue_607_coverage_bundle_http_body(patient_id:, type_json: nil, payor_json: nil, period_json: nil,
                                          subscriber_id_json: nil, total: 1)
    type_json ||= %({"coding":[{"code":"EHCPOL"}]})
    payor_json ||= %([{"reference":"Organization/org1","display":"TEST PAYER"}])
    period_json ||= %({"start":"2026-01-01","end":"2026-12-31"})
    subscriber_id_json ||= %("POL_UTF8")
    resource = %({
      "resourceType":"Coverage",
      "id":"cov_utf8",
      "status":"active",
      "beneficiary":{"reference":"Patient/#{patient_id}"},
      "subscriberId":#{subscriber_id_json},
      "payor":#{payor_json},
      "type":#{type_json},
      "period":#{period_json}
    })
    %({"resourceType":"Bundle","type":"searchset","total":#{total},"entry":[{"resource":#{resource}}]})
  end

  def coverage_search_url(patient_identifier)
    query = URI.encode_www_form(beneficiary: "Patient/#{patient_identifier}")
    "#{@adapter.base_url}/Coverage?#{query}"
  end

  def coverage_bundle(entries:, next_url: nil, next_relation: "next", total: nil, bundle_type: "searchset")
    bundle = {
      "resourceType" => "Bundle",
      "entry" => entries.map { |entry|
        entry.is_a?(Hash) && entry.key?("resource") ? entry : { "resource" => entry }
      }
    }
    bundle["type"] = bundle_type unless bundle_type.nil?
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

  def parity_coverage_resource(patient, suffix, type_code: "MCDSC")
    coverage_fhir_resource(
      id: "cov_#{suffix}",
      for_patient: patient,
      status: "active",
      payer_display: "TEST PAYER #{suffix.upcase}",
      type_code: type_code,
      subscriber_id: "POL_#{suffix.upcase}",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31)
    )
  end

  def assert_rejected_next_link_parity(case_name, responses_by_url, patient, forbidden_urls: [])
    with_stubbed_coverage_http(responses_by_url) do
      assert_nil @adapter.get_coverages(patient), "#{case_name}: get_coverages"
      assert_nil @adapter.send(:fhir_search, "Coverage", beneficiary: "Patient/#{patient}"),
                 "#{case_name}: fhir_search Coverage"
      forbidden_urls.each do |url|
        refute_includes @requested_urls, url, "#{case_name}: must not fetch #{url}"
      end
    end
  end

  def rejected_next_link_parity_cases
    [
      [ "cross_origin_host", method(:parity_case_cross_origin_host) ],
      [ "cross_origin_scheme", method(:parity_case_cross_origin_scheme) ],
      [ "cross_origin_port", method(:parity_case_cross_origin_port) ],
      [ "relative_next_outside_base_path", method(:parity_case_relative_outside_base) ],
      [ "relation_capitalized_next", method(:parity_case_relation_capitalized_next) ],
      [ "relation_next_with_ascii_space", method(:parity_case_relation_next_with_space) ],
      [ "relation_uppercase_next", method(:parity_case_relation_uppercase_next) ],
      [ "relation_is_array", method(:parity_case_relation_is_array) ],
      [ "two_next_links", method(:parity_case_two_next_links) ],
      [ "bundle_link_not_array", method(:parity_case_bundle_link_not_array) ],
      [ "link_entry_not_hash", method(:parity_case_link_entry_not_hash) ],
      [ "next_url_not_string", method(:parity_case_next_url_not_string) ],
      [ "unicode_whitespace_relation", method(:parity_case_unicode_whitespace_relation) ],
      [ "format_character_relation", method(:parity_case_format_character_relation) ],
      [ "next_url_raw_dot_dot", method(:parity_case_next_url_raw_dot_dot) ],
      [ "next_url_percent_encoded_dot_dot", method(:parity_case_next_url_percent_encoded_dot_dot) ],
      [ "next_url_encoded_path_separator", method(:parity_case_next_url_encoded_separator) ],
      [ "next_url_encoded_semicolon", method(:parity_case_next_url_encoded_semicolon) ],
      [ "next_url_double_encoding", method(:parity_case_next_url_double_encoding) ],
      [ "repeated_next_url", method(:parity_case_repeated_next_url) ],
      [ "page_cap_exceeded", method(:parity_case_page_cap_exceeded) ]
    ]
  end

  def parity_case_cross_origin_host(_test, case_name)
    patient = "pt_par_xhost"
    page1_url = coverage_search_url(patient)
    evil_next = "https://evil.example.com/r4/Coverage?#{URI.encode_www_form(page: "2")}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "xh") ], next_url: evil_next)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), evil_next => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ evil_next ]
    )
  end

  def parity_case_cross_origin_scheme(_test, case_name)
    patient = "pt_par_xscheme"
    page1_url = coverage_search_url(patient)
    evil_next = "http://fhir.example.com/r4/Coverage?#{URI.encode_www_form(page: "2")}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "xs") ], next_url: evil_next)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), evil_next => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ evil_next ]
    )
  end

  def parity_case_cross_origin_port(_test, case_name)
    patient = "pt_par_xport"
    page1_url = coverage_search_url(patient)
    evil_next = "https://fhir.example.com:8443/r4/Coverage?#{URI.encode_www_form(page: "2")}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "xp") ], next_url: evil_next)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), evil_next => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ evil_next ]
    )
  end

  def parity_case_relative_outside_base(_test, case_name)
    patient = "pt_par_relpath"
    page1_url = coverage_search_url(patient)
    relative_evil = "/other/Coverage?page=2"
    evil_absolute = "https://fhir.example.com#{relative_evil}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "rp") ], next_url: relative_evil)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), evil_absolute => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ evil_absolute ]
    )
  end

  def parity_case_relation_capitalized_next(_test, case_name)
    patient = "pt_par_nextcap"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [ parity_coverage_resource(patient, "nc") ],
      next_url: page2_url,
      next_relation: "Next"
    )
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), page2_url => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ page2_url ]
    )
  end

  def parity_case_relation_next_with_space(_test, case_name)
    patient = "pt_par_nextsp"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [ parity_coverage_resource(patient, "ns") ],
      next_url: page2_url,
      next_relation: "next "
    )
    assert_rejected_next_link_parity(case_name, { page1_url => http_ok_json(page1) }, patient, forbidden_urls: [ page2_url ])
  end

  def parity_case_relation_uppercase_next(_test, case_name)
    patient = "pt_par_nextup"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(
      entries: [ parity_coverage_resource(patient, "nu") ],
      total: 2,
      next_url: page2_url,
      next_relation: "NEXT"
    )
    page2 = coverage_bundle(entries: [ parity_coverage_resource(patient, "nu2", type_code: "EHCPOL") ], total: 2)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) },
      patient,
      forbidden_urls: [ page2_url ]
    )
  end

  def parity_case_relation_is_array(_test, case_name)
    patient = "pt_par_relarr"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "ra") ])
    page1["link"] = [ { "relation" => [ "next" ], "url" => page2_url } ]
    assert_rejected_next_link_parity(case_name, { page1_url => http_ok_json(page1) }, patient, forbidden_urls: [ page2_url ])
  end

  def parity_case_two_next_links(_test, case_name)
    patient = "pt_par_twonext"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "t2") ])
    page1["link"] = [
      { "relation" => "next", "url" => page2_url },
      { "relation" => "next", "url" => page2_url }
    ]
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), page2_url => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ page2_url ]
    )
  end

  def parity_case_bundle_link_not_array(_test, case_name)
    patient = "pt_par_linkhash"
    page1_url = coverage_search_url(patient)
    page1 = coverage_bundle_total_one(parity_coverage_resource(patient, "lh"))
    page1["link"] = { "relation" => "self", "url" => page1_url }
    assert_rejected_next_link_parity(case_name, { page1_url => http_ok_json(page1) }, patient)
  end

  def parity_case_link_entry_not_hash(_test, case_name)
    patient = "pt_par_linkstr"
    page1_url = coverage_search_url(patient)
    page1 = coverage_bundle_total_one(parity_coverage_resource(patient, "ls"))
    page1["link"] = [
      { "relation" => "self", "url" => page1_url },
      "not-a-link-hash"
    ]
    assert_rejected_next_link_parity(case_name, { page1_url => http_ok_json(page1) }, patient)
  end

  def parity_case_next_url_not_string(_test, case_name)
    patient = "pt_par_urlint"
    page1_url = coverage_search_url(patient)
    page1 = coverage_bundle_total_one(parity_coverage_resource(patient, "ui"))
    page1["link"] = [ { "relation" => "next", "url" => 42 } ]
    assert_rejected_next_link_parity(case_name, { page1_url => http_ok_json(page1) }, patient)
  end

  def parity_case_unicode_whitespace_relation(_test, case_name)
    UNICODE_NEXT_COVERAGE_LINK_RELATIONS.each do |next_relation|
      patient = "pt_par_u8_#{next_relation.bytes.join("_")}"
      page1_url = coverage_search_url(patient)
      page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
      page1 = coverage_bundle(
        entries: [ parity_coverage_resource(patient, "u8") ],
        next_url: page2_url,
        next_relation: next_relation
      )
      assert_rejected_next_link_parity(
        "#{case_name}:#{next_relation.inspect}",
        { page1_url => http_ok_json(page1), page2_url => http_ok_json(coverage_bundle(entries: [])) },
        patient,
        forbidden_urls: [ page2_url ]
      )
    end
  end

  def parity_case_format_character_relation(_test, case_name)
    FORMAT_CHARACTER_NEXT_LINK_RELATIONS.each do |label, next_relation|
      patient = "pt_par_fmt_#{label}"
      page1_url = coverage_search_url(patient)
      page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
      page1 = coverage_bundle(
        entries: [ parity_coverage_resource(patient, "fm") ],
        next_url: page2_url,
        next_relation: next_relation
      )
      assert_rejected_next_link_parity(
        "#{case_name}:#{label}",
        { page1_url => http_ok_json(page1), page2_url => http_ok_json(coverage_bundle(entries: [])) },
        patient,
        forbidden_urls: [ page2_url ]
      )
    end
  end

  def parity_case_next_url_raw_dot_dot(_test, case_name)
    patient = "pt_par_dotdot"
    page1_url = coverage_search_url(patient)
    evil_next = "#{@adapter.base_url}/../admin/Coverage?#{URI.encode_www_form(page: "2")}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "dd") ], next_url: evil_next)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), evil_next => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ evil_next ]
    )
  end

  def parity_case_next_url_percent_encoded_dot_dot(_test, case_name)
    patient = "pt_par_dotenc"
    page1_url = coverage_search_url(patient)
    evil_next = "https://fhir.example.com/r4/%2e%2e/admin/Coverage?#{URI.encode_www_form(page: "2")}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "de") ], next_url: evil_next)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), evil_next => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ evil_next ]
    )
  end

  def parity_case_next_url_encoded_separator(_test, case_name)
    patient = "pt_par_encsep"
    page1_url = coverage_search_url(patient)
    evil_next = "/r4/out%2fadmin/Coverage?#{URI.encode_www_form(page: "2")}"
    resolved = "https://fhir.example.com#{evil_next}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "es") ], next_url: evil_next)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), resolved => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ resolved ]
    )
  end

  def parity_case_next_url_encoded_semicolon(_test, case_name)
    patient = "pt_par_encsemi"
    page1_url = coverage_search_url(patient)
    evil_next = "/r4/..%3b/..%3b/other/r4/Coverage?#{URI.encode_www_form(page: "2")}"
    resolved = "https://fhir.example.com#{evil_next}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "sm") ], next_url: evil_next)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), resolved => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ resolved ]
    )
  end

  def parity_case_next_url_double_encoding(_test, case_name)
    patient = "pt_par_dblenc"
    page1_url = coverage_search_url(patient)
    evil_next = "/r4/out%252fadmin/Coverage?#{URI.encode_www_form(page: "2")}"
    resolved = "https://fhir.example.com#{evil_next}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "dbl") ], next_url: evil_next)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), resolved => http_ok_json(coverage_bundle(entries: [])) },
      patient,
      forbidden_urls: [ resolved ]
    )
  end

  def parity_case_repeated_next_url(_test, case_name)
    patient = "pt_par_loop"
    page1_url = coverage_search_url(patient)
    page2_url = "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: "2", beneficiary: "Patient/#{patient}")}"
    page1 = coverage_bundle(entries: [ parity_coverage_resource(patient, "lp1") ], next_url: page2_url)
    page2 = coverage_bundle(entries: [], next_url: page1_url)
    assert_rejected_next_link_parity(
      case_name,
      { page1_url => http_ok_json(page1), page2_url => http_ok_json(page2) },
      patient
    )
  end

  def parity_case_page_cap_exceeded(_test, case_name)
    patient = "pt_par_cap"
    cap = Corvid::Adapters::FhirAdapter::MAX_COVERAGE_PAGES
    urls = []
    cap.times do |i|
      urls << if i.zero?
        coverage_search_url(patient)
      else
        "#{@adapter.base_url}/Coverage?#{URI.encode_www_form(page: i.to_s, beneficiary: "Patient/#{patient}")}"
      end
    end
    responses = {}
    urls.each_with_index do |url, index|
      next_url = urls[index + 1]
      resource = parity_coverage_resource(patient, "cap#{index}")
      bundle = coverage_bundle(entries: [ resource ], next_url: next_url)
      responses[url] = http_ok_json(bundle)
    end
    assert_rejected_next_link_parity(case_name, responses, patient)
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

  # --- merged from main (#658) ---

  public

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

    @adapter.stub(:http_get, ->(url) { url_seen = url; consumed_json_http_response(bundle) }) do
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

    results = @adapter.stub(:http_get, ->(url) { url_seen = url; consumed_json_http_response(bundle) }) do
      @adapter.get_conditions("pt_001")
    end

    assert_equal expected, url_seen
    assert_equal [], results
  end

  def test_get_conditions_returns_nil_on_non_success_http
    result = get_conditions_with_http_response(consumed_json_http_response("{}", status: 500))

    assert_nil result
  end

  def test_get_conditions_returns_nil_on_invalid_json
    result = get_conditions_with_http_response(consumed_json_http_response("not json"))

    assert_nil result
  end

  def test_get_conditions_returns_nil_when_response_is_not_a_bundle
    result = get_conditions_with_http_response(consumed_json_http_response({ "resourceType" => "Patient", "id" => "pt_001" }))

    assert_nil result
  end

  def test_get_conditions_returns_nil_when_bundle_contains_fatal_operation_outcome
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => { "resourceType" => "OperationOutcome", "issue" => [ { "severity" => "fatal", "code" => "processing" } ] } } ]
    }
    result = get_conditions_with_http_response(consumed_json_http_response(bundle))

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

    @adapter.stub(:http_get, ->(url) { url_seen = url; consumed_json_http_response(bundle) }) do
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

    results = @adapter.stub(:http_get, ->(url) { url_seen = url; consumed_json_http_response(bundle) }) do
      @adapter.get_medications("pt_001")
    end

    assert_equal expected, url_seen
    assert_equal [], results
  end

  def test_get_medications_returns_nil_on_non_success_http
    result = get_medications_with_http_response(consumed_json_http_response("{}", status: 503))

    assert_nil result
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

  def test_get_conditions_returns_nil_when_condition_clinical_code_is_not_fhir_allowed
    condition = build_condition_resource(
      clinical_status: "Active",
      clinical_status_system: CONDITION_CLINICAL_SYSTEM
    )
    assert_nil get_conditions_with_bundle(conditions_bundle([ condition ]))
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

  TRUST_DEFEATING_OUTCOME_CODES = %w[
    suppressed incomplete too-costly timeout throttled too-long exception
  ].freeze

  INEXACT_TRUST_DEFEATING_OUTCOME_CODES = [
    "Suppressed",
    "incomplete ",
    " TOO-COSTLY",
    "Timeout"
  ].freeze

  OUTCOME_SEVERITIES = %w[fatal error warning information].freeze

  def test_get_conditions_returns_nil_when_operation_outcome_has_untrusted_code_at_any_severity
    condition = build_condition_resource
    TRUST_DEFEATING_OUTCOME_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = conditions_bundle_with_operation_outcome([ condition ], issue_code: code, severity: severity)
        assert_nil get_conditions_with_bundle(bundle),
                   "expected nil for OperationOutcome #{severity}/#{code} on Condition search"
      end
    end
  end

  def test_get_medications_returns_nil_when_operation_outcome_has_untrusted_code_at_any_severity
    request = build_medication_request_resource
    TRUST_DEFEATING_OUTCOME_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = medications_bundle_with_operation_outcome([ request ], issue_code: code, severity: severity)
        assert_nil get_medications_with_bundle(bundle),
                   "expected nil for OperationOutcome #{severity}/#{code} on MedicationRequest search"
      end
    end
  end

  def test_get_conditions_returns_nil_when_operation_outcome_has_inexact_untrusted_code_at_any_severity
    condition = build_condition_resource
    INEXACT_TRUST_DEFEATING_OUTCOME_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = conditions_bundle_with_operation_outcome([ condition ], issue_code: code, severity: severity)
        assert_nil get_conditions_with_bundle(bundle),
                   "expected nil for malformed or untrusted OperationOutcome #{severity}/#{code.inspect}"
      end
    end
  end

  def test_get_medications_returns_nil_when_operation_outcome_has_inexact_untrusted_code_at_any_severity
    request = build_medication_request_resource
    INEXACT_TRUST_DEFEATING_OUTCOME_CODES.each do |code|
      OUTCOME_SEVERITIES.each do |severity|
        bundle = medications_bundle_with_operation_outcome([ request ], issue_code: code, severity: severity)
        assert_nil get_medications_with_bundle(bundle),
                   "expected nil for malformed or untrusted OperationOutcome #{severity}/#{code.inspect}"
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

  def coverage_period_bundle(period)
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

  def eligibility_for_period(period)
    @adapter.stub(:fhir_search, coverage_period_bundle(period)) do
      @adapter.verify_eligibility("pt_test_001", "medicaid")
    end
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

  def no_content_http_response
    response = Net::HTTPNoContent.new("1.1", "204", "No Content")
    response.instance_variable_set(:@body, nil)
    response.instance_variable_set(:@read, true)
    response
  end

  def get_medications_with_bundle_without_extra_http(bundle, patient_id: "pt_001")
    http_calls = 0
    response = consumed_json_http_response(bundle)
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

  def clinical_read_without_http(method, patient_identifier)
    http_calls = 0
    @adapter.stub(:http_get, ->(_url) { http_calls += 1; flunk("http_get must not run") }) do
      result = @adapter.public_send(method, patient_identifier)
      assert_equal 0, http_calls
      result
    end
  end

  def consumed_json_http_response(body, status: 200)
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
    get_conditions_with_http_response(consumed_json_http_response(bundle), patient_id: patient_id)
  end

  def get_conditions_with_http_response(response, patient_id: "pt_001")
    @adapter.stub(:http_get, response) { @adapter.get_conditions(patient_id) }
  end

  def get_conditions_with_http_error(error)
    @adapter.stub(:http_get, ->(_url) { raise error }) { @adapter.get_conditions("pt_001") }
  end

  def get_medications_with_bundle(bundle, patient_id: "pt_001")
    get_medications_with_http_response(consumed_json_http_response(bundle), patient_id: patient_id)
  end

  def get_medications_with_http_response(response, patient_id: "pt_001")
    @adapter.stub(:http_get, response) { @adapter.get_medications(patient_id) }
  end
end
