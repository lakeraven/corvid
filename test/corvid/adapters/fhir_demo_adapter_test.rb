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
    results = @adapter.get_conditions("pt_demo_001")

    refute_nil results
    assert_equal 1, results.size
    ref = results.first
    assert_instance_of Corvid::ConditionReference, ref
    assert_equal "C-DEMO-001", ref.code
    assert_equal "problem-list-item", ref.category
    assert_equal "active", ref.clinical_status
  end

  def test_get_medications_serves_mapped_medication_references_from_in_memory_store
    results = @adapter.get_medications("pt_demo_001")

    refute_nil results
    assert_equal 1, results.size
    ref = results.first
    assert_instance_of Corvid::MedicationReference, ref
    assert_equal "M-DEMO-001", ref.code
    assert_equal "active", ref.status
  end

  private

  def synthetic_condition
    {
      "resourceType" => "Condition",
      "id" => "cond_demo_001",
      "subject" => { "reference" => "Patient/pt_demo_001" },
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
      "subject" => { "reference" => "Patient/pt_demo_001" },
      "authoredOn" => "2024-01-15",
      "medicationReference" => { "reference" => "Medication/med_demo_001" },
      "dosageInstruction" => [ { "text" => "TEST DEMO DOSAGE 001" } ]
    }
  end
end
