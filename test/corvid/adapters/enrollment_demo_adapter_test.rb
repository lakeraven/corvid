# frozen_string_literal: true

require "minitest/autorun"
require "corvid/adapters/enrollment_demo_adapter"
require "corvid/fhir_reference"

class Corvid::Adapters::EnrollmentDemoAdapterTest < Minitest::Test
  def setup
    @adapter = Corvid::Adapters::EnrollmentDemoAdapter.new
  end

  def test_demo_enrolled_patient_returns_verified_confidence
    result = @adapter.verify_tribal_enrollment("pt-demo-enrolled")
    assert result[:enrolled]
    assert_equal :verified, result[:confidence]
  end

  def test_demo_off_reservation_enrolled_patient_returns_verified_confidence
    result = @adapter.verify_tribal_enrollment("pt-demo-off-reservation")
    assert result[:enrolled]
    assert_equal :verified, result[:confidence]
  end

  def test_demo_nonenrolled_patient_returns_unavailable_confidence
    result = @adapter.verify_tribal_enrollment("pt-demo-nonenrolled")
    refute result[:enrolled]
    assert_equal :unavailable, result[:confidence]
  end

  def test_unknown_patient_returns_nil_enrolled_with_unavailable_confidence
    result = @adapter.verify_tribal_enrollment("pt_demo_unknown")
    assert_nil result[:enrolled]
    assert_equal :unavailable, result[:confidence]
  end

  def test_seeded_prc_manager_practitioner_id_is_valid_for_fhir_reference_lookup
    practitioner_id = "pr-demo-001"
    practitioner = @adapter.find_practitioner(practitioner_id)
    assert practitioner, "expected seeded PRC manager at #{practitioner_id}"
    assert_equal practitioner_id,
                 Corvid::FhirReference.id_from("Practitioner/#{practitioner_id}", type: "Practitioner")
  end
end
