# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all" # adapter uses AS ext (blank?, present?); loaded by the host app in real use
require "corvid/adapters/fhir_demo_adapter"

class Corvid::Adapters::FhirDemoAdapterTest < Minitest::Test
  CONDITION_CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-category"

  def setup
    @condition = synthetic_condition
    @medication = synthetic_medication
    @medication_request = synthetic_medication_request
    @adapter = Corvid::Adapters::FhirDemoAdapter.new(
      resources: [ @condition, @medication_request, @medication ]
    )
  end

  def test_get_conditions_serves_mapped_condition_references_from_in_memory_store
    results = @adapter.get_conditions("pt-demo-001")

    refute_nil results
    assert_equal 1, results.size
    ref = results.first
    assert_instance_of Corvid::ConditionReference, ref
    assert_equal "C-DEMO-001", ref.code
    assert_equal "problem-list-item", ref.category
    assert_equal "active", ref.clinical_status
  end

  def test_get_medications_serves_mapped_medication_references_from_in_memory_store
    results = @adapter.get_medications("pt-demo-001")

    refute_nil results
    assert_equal 1, results.size
    ref = results.first
    assert_instance_of Corvid::MedicationReference, ref
    assert_equal "M-DEMO-001", ref.code
    assert_equal "active", ref.status
  end

  def test_get_conditions_finds_condition_when_subject_reference_is_absolute_under_demo_base_url
    condition = synthetic_condition.merge(
      "subject" => { "reference" => "#{@adapter.base_url}/Patient/pt-demo-001" }
    )
    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ condition ])

    results = adapter.get_conditions("pt-demo-001")

    refute_nil results
    assert_equal 1, results.size
    assert_equal "C-DEMO-001", results.first.code
  end

  def test_get_conditions_finds_condition_when_subject_reference_includes_history_version
    [
      "Patient/pt-demo-001/_history/1",
      "#{@adapter.base_url}/Patient/pt-demo-001/_history/1"
    ].each do |reference|
      condition = synthetic_condition.merge("subject" => { "reference" => reference })
      adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ condition ])

      results = adapter.get_conditions("pt-demo-001")

      refute_nil results, "expected match for #{reference}"
      assert_equal 1, results.size
      assert_equal "C-DEMO-001", results.first.code
    end
  end

  def test_get_conditions_does_not_match_foreign_absolute_patient_url_for_local_id
    condition = synthetic_condition.merge(
      "subject" => { "reference" => "https://other-ehr.example/fhir/Patient/pt-demo-001/_history/1" }
    )
    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ condition ])

    refute adapter.get_conditions("pt-demo-001")&.any?
  end

  def test_get_conditions_does_not_match_empty_patient_reference_tokens
    empty_ref_variants = [
      { "reference" => "Patient/" },
      { "reference" => "Patient/ " },
      { "reference" => "#{@adapter.base_url}/Patient/" },
      { "reference" => "#{@adapter.base_url}/Patient/ " }
    ]
    empty_ref_variants.each do |subject|
      condition = synthetic_condition.merge("subject" => subject)
      adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ condition ])

      refute adapter.get_conditions("pt-demo-001")&.any?,
             "Patient/ reference must not match patient pt_demo_001 (#{subject.inspect})"

      bundle = adapter.send(:fhir_search, "Condition", { "patient" => "" })
      assert_equal 0, bundle["total"],
                   "Patient/ reference must not match blank patient search (#{subject.inspect})"
    end
  end

  def test_list_claims_does_not_match_empty_patient_reference_tokens
    claim = synthetic_claim.merge("patient" => { "reference" => "Patient/" })
    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ claim ])

    assert_equal [], adapter.list_claims("Patient/"),
                 "Claim with Patient/ must not appear under list_claims(\"Patient/\")"

    bundle = adapter.send(:fhir_search, "Claim", { "patient" => "" })
    assert_equal 0, bundle["total"],
                   "Claim with Patient/ must not match Claim?patient= blank search"

    blank_patient_ref = synthetic_claim.merge("patient" => { "reference" => "" })
    blank_adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ blank_patient_ref ])
    blank_bundle = blank_adapter.send(:fhir_search, "Claim", { "patient" => "" })
    assert_equal 0, blank_bundle["total"],
                   "blank patient search must not match claim with empty patient reference"
  end

  # The overlay demo installs this adapter as Corvid.adapter, so referral
  # writes must work in memory instead of reaching for HTTP.
  def test_create_referral_stores_a_service_request_that_reads_find_and_list
    token = @adapter.create_referral("pt-demo-001", { reason: "TEST REASON" })

    assert_instance_of String, token
    refute_empty token
    ref = @adapter.find_referral(token)
    assert_instance_of Corvid::ReferralReference, ref
    assert_equal token, ref.identifier
    assert_equal "pt-demo-001", ref.patient_identifier
    assert_equal "draft", ref.status
    assert_includes @adapter.list_referrals("pt-demo-001").map(&:identifier), token
    assert_empty @adapter.list_referrals("pt_demo_other")
  end

  def test_create_referral_gives_each_referral_its_own_identifier
    first = @adapter.create_referral("pt-demo-001", {})
    second = @adapter.create_referral("pt-demo-001", {})

    refute_equal first, second
    assert_equal [ first, second ].sort, @adapter.list_referrals("pt-demo-001").map(&:identifier).sort
  end

  def test_update_referral_changes_the_stored_service_request
    token = @adapter.create_referral("pt-demo-001", {})

    assert_equal true, @adapter.update_referral(token, { status: "active", chs_approval_status: "A" })
    assert_equal "active", @adapter.find_referral(token).status
    assert_equal [ "active" ], @adapter.list_referrals("pt-demo-001").map(&:status)
  end

  def test_update_referral_on_unknown_referral_returns_false_and_stores_nothing
    refute @adapter.update_referral("rf_demo_unknown", { status: "active" })
    assert_nil @adapter.find_referral("rf_demo_unknown")
  end

  def test_update_referral_on_a_seeded_service_request_is_visible_to_reads
    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ synthetic_service_request ])

    assert_equal true, adapter.update_referral("rf_demo_001", { status: "on-hold" })
    assert_equal "on-hold", adapter.find_referral("rf_demo_001").status
  end

  private

  def synthetic_service_request
    {
      "resourceType" => "ServiceRequest",
      "id" => "rf_demo_001",
      "status" => "active",
      "intent" => "order",
      "subject" => { "reference" => "Patient/pt-demo-001" }
    }
  end

  def synthetic_condition
    {
      "resourceType" => "Condition",
      "id" => "cond_demo_001",
      "subject" => { "reference" => "Patient/pt-demo-001" },
      "category" => [ {
        "coding" => [ { "system" => CONDITION_CATEGORY_SYSTEM, "code" => "problem-list-item" } ]
      } ],
      "clinicalStatus" => { "coding" => [ { "code" => "active" } ] },
      "code" => {
        "coding" => [ {
          "system" => "http://example.test/codes",
          "code" => "C-DEMO-001",
          "display" => "TEST DEMO CONDITION 001"
        } ]
      },
      "onsetDateTime" => "2021-05-10"
    }
  end

  def synthetic_medication
    {
      "resourceType" => "Medication",
      "id" => "med_demo_001",
      "code" => {
        "coding" => [ {
          "system" => "http://example.test/rxnorm",
          "code" => "M-DEMO-001",
          "display" => "TEST DEMO MEDICATION 001"
        } ]
      }
    }
  end

  def synthetic_medication_request
    {
      "resourceType" => "MedicationRequest",
      "id" => "mr_demo_001",
      "status" => "active",
      "subject" => { "reference" => "Patient/pt-demo-001" },
      "authoredOn" => "2024-01-15",
      "medicationReference" => { "reference" => "Medication/med_demo_001" },
      "dosageInstruction" => [ { "text" => "TEST DEMO DOSAGE 001" } ]
    }
  end

  def synthetic_claim
    {
      "resourceType" => "Claim",
      "id" => "clm_demo_001",
      "patient" => { "reference" => "Patient/pt-demo-001" },
      "item" => [ {
        "sequence" => 1,
        "productOrService" => {
          "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ]
        },
        "net" => { "value" => 100.0, "currency" => "USD" }
      } ]
    }
  end
end
