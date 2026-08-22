# frozen_string_literal: true

require "minitest/autorun"
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
end
