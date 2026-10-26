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

  def test_get_conditions_finds_condition_when_subject_reference_is_absolute_under_demo_base_url
    condition = synthetic_condition.merge(
      "subject" => { "reference" => "#{@adapter.base_url}/Patient/pt_demo_001" }
    )
    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ condition ])

    results = adapter.get_conditions("pt_demo_001")

    refute_nil results
    assert_equal 1, results.size
    assert_equal "C-DEMO-001", results.first.code
  end

  def test_get_coverages_returns_mapped_active_coverage_from_in_memory_store
    coverage = synthetic_demo_coverage(for_patient: "pt_demo_cov")
    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ coverage ])

    result = adapter.get_coverages("pt_demo_cov")

    refute_nil result
    assert_equal 1, result.size
    assert_equal({
      payer_name: "TEST DEMO PAYER COV",
      plan_name: "TEST DEMO PLAN COV",
      coverage_type: "MCDSC",
      policy_number: "POL_DEMO_COV",
      coverage_start: Date.new(2020, 1, 1),
      coverage_end: Date.new(2030, 12, 31),
      status: "active"
    }, result.first)
  end

  def test_deep_base_path_demo_subclass_maps_coverage_from_in_memory_store
    coverage = synthetic_demo_coverage(for_patient: "pt_demo_deep_cov")
    adapter = deep_base_fhir_demo_adapter(resources: [ coverage ])

    result = adapter.get_coverages("pt_demo_deep_cov")

    refute_nil result
    assert_equal 1, result.size
    assert_equal "POL_DEMO_COV", result.first[:policy_number]
  end

  def test_get_coverages_returns_empty_array_when_patient_has_no_coverage_in_memory_store
    adapter = Corvid::Adapters::FhirDemoAdapter.new(
      resources: [ synthetic_condition ]
    )

    result = adapter.get_coverages("pt_demo_no_cov")

    assert_equal [], result
  end

  def test_get_coverages_does_not_raise_for_patient_with_or_without_coverage
    with_cov = Corvid::Adapters::FhirDemoAdapter.new(
      resources: [ synthetic_demo_coverage(for_patient: "pt_demo_cov") ]
    )
    without_cov = Corvid::Adapters::FhirDemoAdapter.new(resources: [])

    with_cov.get_coverages("pt_demo_cov")
    without_cov.get_coverages("pt_demo_cov")
  end

  # The overlay demo installs this adapter as Corvid.adapter, so referral
  # writes must work in memory instead of reaching for HTTP.
  def test_create_referral_stores_a_service_request_that_reads_find_and_list
    token = @adapter.create_referral("pt_demo_001", { reason: "TEST REASON" })

    assert_instance_of String, token
    refute_empty token
    ref = @adapter.find_referral(token)
    assert_instance_of Corvid::ReferralReference, ref
    assert_equal token, ref.identifier
    assert_equal "pt_demo_001", ref.patient_identifier
    assert_equal "draft", ref.status
    assert_includes @adapter.list_referrals("pt_demo_001").map(&:identifier), token
    assert_empty @adapter.list_referrals("pt_demo_other")
  end

  def test_create_referral_gives_each_referral_its_own_identifier
    first = @adapter.create_referral("pt_demo_001", {})
    second = @adapter.create_referral("pt_demo_001", {})

    refute_equal first, second
    assert_equal [ first, second ].sort, @adapter.list_referrals("pt_demo_001").map(&:identifier).sort
  end

  def test_update_referral_changes_the_stored_service_request
    token = @adapter.create_referral("pt_demo_001", {})

    assert_equal true, @adapter.update_referral(token, { status: "active", chs_approval_status: "A" })
    assert_equal "active", @adapter.find_referral(token).status
    assert_equal [ "active" ], @adapter.list_referrals("pt_demo_001").map(&:status)
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

  def deep_base_fhir_demo_adapter(resources:)
    klass = Class.new(Corvid::Adapters::FhirDemoAdapter) do
      define_method(:initialize) do |resources: []|
        super(resources: resources)
        @base_url = "memory://fhir-demo/a/b/r4".freeze
      end
    end
    klass.new(resources: resources)
  end

  def synthetic_service_request
    {
      "resourceType" => "ServiceRequest",
      "id" => "rf_demo_001",
      "status" => "active",
      "intent" => "order",
      "subject" => { "reference" => "Patient/pt_demo_001" }
    }
  end

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

  def synthetic_demo_coverage(for_patient:)
    {
      "resourceType" => "Coverage",
      "id" => "cov_demo_cov",
      "status" => "active",
      "beneficiary" => { "reference" => "Patient/#{for_patient}" },
      "subscriberId" => "POL_DEMO_COV",
      "payor" => [
        {
          "reference" => "Organization/cov_demo_cov",
          "display" => "TEST DEMO PAYER COV"
        }
      ],
      "type" => { "coding" => [ { "code" => "MCDSC" } ] },
      "period" => { "start" => "2020-01-01", "end" => "2030-12-31" },
      "class" => [
        {
          "type" => { "coding" => [ { "code" => "plan" } ] },
          "name" => "TEST DEMO PLAN COV"
        }
      ]
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
