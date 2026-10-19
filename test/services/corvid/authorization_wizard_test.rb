# frozen_string_literal: true

require "test_helper"

class Corvid::AuthorizationWizardTest < ActiveSupport::TestCase
  TENANT = "tnt_auth_wiz"

  test "set_resource_status accepts coordinated" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )

      wizard.set_resource_status("medicaid", "coordinated")
      assert_equal :coordinated, wizard.alternate_resources["medicaid"][:status]
      refute wizard.alternate_resources["medicaid"][:requires_coordination]
    end
  end

  test "alternate_resources_exhausted? counts coordinated among determined resources" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )

      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        status = type == "medicaid" ? "coordinated" : "not_enrolled"
        wizard.set_resource_status(type, status)
      end

      assert wizard.alternate_resources_exhausted?
    end
  end

  test "summary alternate_resources_status is Verified when all resources determined including coordinated" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )

      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each_with_index do |type, index|
        status =
          case index % 4
          when 0 then "not_enrolled"
          when 1 then "denied"
          when 2 then "exhausted"
          else "coordinated"
          end
        wizard.set_resource_status(type, status)
      end

      assert_equal "Verified", wizard.summary[:alternate_resources_status]
    end
  end
end
