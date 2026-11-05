# frozen_string_literal: true

require "test_helper"

module Corvid
  class CareTeamRoleCodeFhirTest < ActiveSupport::TestCase
    TENANT = "tnt_ct_fhir_role"
    FACILITY = "fac_ct_fhir_role"
    ENGINE_ROLE_SYSTEM = "urn:corvid:care-team-role"

    setup do
      Corvid::TenantContext.current_tenant_identifier = TENANT
    end

    test "add_member! persists role_code not free text" do
      assert_role_code_api!
      team = CareTeam.create!(name: "FHIR role team", facility_identifier: FACILITY)
      member = team.add_member!(role_code: "care_manager", practitioner_identifier: "pr_fhir_a")
      assert_equal "care_manager", member.role_code
      refute_respond_to member, :role
    end

    test "to_fhir participant role uses engine coding and derived display" do
      assert_role_code_api!
      team = CareTeam.create!(name: "FHIR export", facility_identifier: FACILITY)
      team.add_member!(role_code: "primary_care_provider", practitioner_identifier: "pr_fhir_b")

      role_entry = team.to_fhir[:participant].sole[:role].sole
      coding = role_entry.fetch(:coding).sole
      assert_equal ENGINE_ROLE_SYSTEM, coding[:system]
      assert_equal "primary_care_provider", coding[:code]
      assert_equal "Primary care provider", coding[:display]
      refute role_entry.key?(:text), "participant role must not echo legacy free text"
    end

    private

    def assert_role_code_api!
      assert_includes CareTeam.instance_method(:add_member!).parameters.flatten, :role_code
      refute_includes CareTeamMember.column_names, "role"
    end
  end
end
