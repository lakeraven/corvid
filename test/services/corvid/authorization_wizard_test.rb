# frozen_string_literal: true

require "test_helper"

class Corvid::AuthorizationWizardTest < ActiveSupport::TestCase
  TENANT = "tnt_wizard_blank"

  test "initialize treats blank tenant_identifier as absent and uses TenantContext" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(tenant_identifier: "")
      assert_equal TENANT, wizard.tenant_identifier
    end
  end

  test "initialize treats whitespace tenant_identifier as absent and uses TenantContext" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(tenant_identifier: "   ")
      assert_equal TENANT, wizard.tenant_identifier
    end
  end

  test "initialize raises when tenant_identifier is blank and TenantContext has no tenant" do
    error = assert_raises(ArgumentError) do
      Corvid::AuthorizationWizard.new(tenant_identifier: "")
    end
    assert_match(/tenant_identifier required/, error.message)
  end

  test "initialize raises when ambient TenantContext tenant_identifier is blank" do
    Corvid::TenantContext.current_tenant_identifier = ""
    error = assert_raises(ArgumentError) do
      Corvid::AuthorizationWizard.new
    end
    assert_match(/tenant_identifier required/, error.message)
  ensure
    Corvid::TenantContext.reset!
  end

  test "initialize raises when ambient TenantContext tenant_identifier is whitespace" do
    Corvid::TenantContext.current_tenant_identifier = "   "
    error = assert_raises(ArgumentError) do
      Corvid::AuthorizationWizard.new
    end
    assert_match(/tenant_identifier required/, error.message)
  ensure
    Corvid::TenantContext.reset!
  end

  test "initialize treats blank facility_identifier as absent and uses TenantContext facility" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = "fac_ambient"
      wizard = Corvid::AuthorizationWizard.new(facility_identifier: "")
      assert_equal "fac_ambient", wizard.facility_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "initialize treats whitespace facility_identifier as absent and uses TenantContext facility" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = "fac_ambient"
      wizard = Corvid::AuthorizationWizard.new(facility_identifier: "  ")
      assert_equal "fac_ambient", wizard.facility_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "initialize treats blank ambient facility_identifier as absent" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = ""
      wizard = Corvid::AuthorizationWizard.new
      assert_nil wizard.facility_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

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

  # ---- Issue #662: patient eligibility status must not default to verified ----

  test "patient_eligibility_status is nil when host never sets it" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )

      assert_nil wizard.patient_eligibility_status
    end
  end

  test "start! warns when patient eligibility status was never set" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.start!

      assert_includes wizard.warnings, "Patient eligibility verification pending"
    end
  end

  test "start! does not warn when patient eligibility status is explicitly verified" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.patient_eligibility_status = "verified"
      wizard.start!

      refute_includes wizard.warnings, "Patient eligibility verification pending"
    end
  end

  test "start! warns when patient eligibility status is explicitly pending" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.patient_eligibility_status = "pending"
      wizard.start!

      assert_includes wizard.warnings, "Patient eligibility verification pending"
    end
  end

  test "start! warns when patient eligibility status is empty string" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.patient_eligibility_status = ""
      wizard.start!

      assert_includes wizard.warnings, "Patient eligibility verification pending"
    end
  end

  test "start! warns when patient eligibility status is unverified" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.patient_eligibility_status = "unverified"
      wizard.start!

      assert_includes wizard.warnings, "Patient eligibility verification pending"
    end
  end

  test "start! warns when patient eligibility status is ineligible" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.patient_eligibility_status = "ineligible"
      wizard.start!

      assert_includes wizard.warnings, "Patient eligibility verification pending"
    end
  end

  test "start! does not treat unset eligibility as verified on the wizard" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.start!

      refute_equal "verified", wizard.patient_eligibility_status
    end
  end

  # ---- Issue #662 round 2: eligibility warning at read time ----------------

  ELIGIBILITY_PENDING_WARNING = "Patient eligibility verification pending"

  def fill_wizard_for_submit!(wizard)
    wizard.data.merge!(
      service_requested: "Cardiology Consultation",
      reason_for_referral: "TEST REASON",
      medical_priority: 3,
      estimated_cost: 5_000
    )
  end

  test "warnings include eligibility pending when patient is assigned after start without verified status" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(facility_identifier: "fac_test")
      wizard.start!

      refute_includes wizard.warnings, ELIGIBILITY_PENDING_WARNING

      wizard.patient_identifier = "pt_late_assign"
      assert_includes wizard.warnings, ELIGIBILITY_PENDING_WARNING
    end
  end

  test "setting patient eligibility status to verified after start removes pending warning at read time" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.start!
      assert_includes wizard.warnings, ELIGIBILITY_PENDING_WARNING

      wizard.patient_eligibility_status = "verified"
      refute_includes wizard.warnings, ELIGIBILITY_PENDING_WARNING
    end
  end

  test "setting patient eligibility status back to pending restores pending warning at read time" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.patient_eligibility_status = "verified"
      wizard.start!
      refute_includes wizard.warnings, ELIGIBILITY_PENDING_WARNING

      wizard.patient_eligibility_status = "pending"
      assert_includes wizard.warnings, ELIGIBILITY_PENDING_WARNING
    end
  end

  test "eligibility pending warning appears at most once in warnings" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz",
        facility_identifier: "fac_test"
      )
      wizard.start!

      3.times { wizard.warnings }
      assert_equal 1, wizard.warnings.count(ELIGIBILITY_PENDING_WARNING)
    end
  end

  test "submit! includes eligibility pending warning and still succeeds when status is not verified" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_wiz_submit",
        facility_identifier: "fac_test"
      )
      wizard.patient_eligibility_status = "pending"
      fill_wizard_for_submit!(wizard)

      result = wizard.submit!

      assert result[:success], "submit should not be blocked by eligibility pending warning"
      assert_includes wizard.warnings, ELIGIBILITY_PENDING_WARNING
      assert_includes result[:warnings], ELIGIBILITY_PENDING_WARNING
    end
  end
end
