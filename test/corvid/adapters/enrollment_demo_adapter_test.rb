# frozen_string_literal: true

require "minitest/autorun"
require "corvid/adapters/enrollment_demo_adapter"

class Corvid::Adapters::EnrollmentDemoAdapterTest < Minitest::Test
  def setup
    @adapter = Corvid::Adapters::EnrollmentDemoAdapter.new
  end

  def test_demo_enrolled_patient_returns_verified_confidence
    result = @adapter.verify_tribal_enrollment("pt_demo_enrolled")
    assert result[:enrolled]
    assert_equal :verified, result[:confidence]
  end

  def test_demo_off_reservation_enrolled_patient_returns_verified_confidence
    result = @adapter.verify_tribal_enrollment("pt_demo_off_reservation")
    assert result[:enrolled]
    assert_equal :verified, result[:confidence]
  end

  def test_demo_nonenrolled_patient_returns_unavailable_confidence
    result = @adapter.verify_tribal_enrollment("pt_demo_nonenrolled")
    refute result[:enrolled]
    assert_equal :unavailable, result[:confidence]
  end

  def test_unknown_patient_returns_nil_enrolled_with_unavailable_confidence
    result = @adapter.verify_tribal_enrollment("pt_demo_unknown")
    assert_nil result[:enrolled]
    assert_equal :unavailable, result[:confidence]
  end
end
