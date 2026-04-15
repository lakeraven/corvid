# frozen_string_literal: true

require "corvid/adapters/enrollment_demo_adapter"

Given("the enrollment demo adapter is active") do
  @previous_adapter = Corvid.adapter
  @adapter = Corvid::Adapters::EnrollmentDemoAdapter.new
  Corvid.configure { |c| c.adapter = @adapter }
end

After do
  if @previous_adapter
    Corvid.configure { |c| c.adapter = @previous_adapter }
    @previous_adapter = nil
  end
end

When("I verify tribal enrollment for the demo patient") do
  @enrollment_result = @adapter.verify_tribal_enrollment("pt_demo_enrolled")
end

When("I verify identity documents for the demo patient") do
  @identity_result = @adapter.verify_identity_documents("pt_demo_enrolled")
end

When("I verify residency for the demo patient") do
  @residency_result = @adapter.verify_residency("pt_demo_enrolled")
end

When("I verify tribal enrollment for a non-enrolled person") do
  @enrollment_result = @adapter.verify_tribal_enrollment("pt_demo_nonenrolled")
end

When("I verify residency for an off-reservation person") do
  @residency_result = @adapter.verify_residency("pt_demo_off_reservation")
end
