# frozen_string_literal: true

require "test_helper"

class Corvid::CareTeamTest < ActiveSupport::TestCase
  TENANT = "tnt_ct_test"

  setup do
    Corvid::CareTeamMember.unscoped.delete_all
    Corvid::CareTeam.unscoped.delete_all
  end

  test "add_member! demotes any prior lead when adding a new lead" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team A", facility_identifier: "fac_a")
      team.add_member!(role: "Lead 1", practitioner_identifier: "pr_001", lead: true)
      team.add_member!(role: "Lead 2", practitioner_identifier: "pr_002", lead: true)

      leads = team.care_team_members.where(lead: true).pluck(:practitioner_identifier)
      assert_equal [ "pr_002" ], leads,
        "expected previous lead to be demoted when a new lead is added"
      assert_equal 2, team.care_team_members.count,
        "previous lead should remain a member, just not the lead"
    end
  end

  test "add_member! with lead: false preserves existing lead" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team B", facility_identifier: "fac_a")
      team.add_member!(role: "Lead", practitioner_identifier: "pr_001", lead: true)
      team.add_member!(role: "Member", practitioner_identifier: "pr_002", lead: false)

      assert_equal "pr_001", team.lead_member.practitioner_identifier
    end
  end

  test "remove_member! removes the row for that practitioner" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team C", facility_identifier: "fac_a")
      team.add_member!(role: "PCP", practitioner_identifier: "pr_001")
      team.add_member!(role: "Care Manager", practitioner_identifier: "pr_002")

      team.remove_member!("pr_001")
      remaining = team.care_team_members.pluck(:practitioner_identifier)
      assert_equal [ "pr_002" ], remaining
    end
  end

  test "active_members excludes members with past end_date" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team D", facility_identifier: "fac_a")
      team.add_member!(role: "Active", practitioner_identifier: "pr_a")
      team.add_member!(role: "Past", practitioner_identifier: "pr_b",
        end_date: Date.current - 30)

      actives = team.active_members.pluck(:practitioner_identifier)
      assert_equal [ "pr_a" ], actives
    end
  end

  test "active_teams scope only includes status=active" do
    with_tenant(TENANT) do
      Corvid::CareTeam.create!(name: "Active", facility_identifier: "fac_a", status: "active")
      Corvid::CareTeam.create!(name: "Inactive", facility_identifier: "fac_a", status: "inactive")

      names = Corvid::CareTeam.active_teams.pluck(:name)
      assert_includes names, "Active"
      refute_includes names, "Inactive"
    end
  end

  test "to_fhir emits a CareTeam resource with participant entries" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "FHIR Team", facility_identifier: "fac_a")
      team.add_member!(role: "PCP", practitioner_identifier: "pr_001")
      team.add_member!(role: "Care Manager", practitioner_identifier: "pr_002")

      fhir = team.to_fhir
      assert_equal "CareTeam", fhir[:resourceType]
      assert_equal "FHIR Team", fhir[:name]
      assert_equal "active", fhir[:status]
      assert_equal 2, fhir[:participant].size
      assert_equal "Organization/fac_a", fhir[:managingOrganization][0][:reference]
    end
  end

  test "to_fhir omits inactive members from participant list" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team E", facility_identifier: "fac_a")
      team.add_member!(role: "Active", practitioner_identifier: "pr_a")
      team.add_member!(role: "Former", practitioner_identifier: "pr_b",
        end_date: Date.current - 1)

      participants = team.to_fhir[:participant].map { |p| p[:member][:reference] }
      assert_equal [ "Practitioner/pr_a" ], participants
    end
  end
end
