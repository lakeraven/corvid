# frozen_string_literal: true

require "test_helper"

# Issue #712 round 2: AuthorizationWizard#enrollment_status_from binding pins.
class Corvid::AuthorizationWizardEnrollmentStatus712Test < ActiveSupport::TestCase
  def setup
    @wizard = Corvid::AuthorizationWizard.new(
      patient_identifier: "pt_712_wiz",
      tenant_identifier: "tnt_test",
      facility_identifier: "fac_test"
    )
  end

  test "enrollment_status_from is nil when service_active is false and eligible is absent" do
    assert_nil status_from({ service_active: false })
  end

  test "enrollment_status_from is nil when eligible is a non-boolean string" do
    assert_nil status_from({ service_active: false, eligible: "yes" })
  end

  test "enrollment_status_from is nil when eligible uses a string key" do
    assert_nil status_from({ "eligible" => true, service_active: false })
  end

  test "enrollment_status_from is not_enrolled when eligible is true and service_active is false" do
    assert_equal :not_enrolled, status_from({ eligible: true, service_active: false })
  end

  private

  def status_from(result)
    @wizard.send(:enrollment_status_from, result)
  end
end
