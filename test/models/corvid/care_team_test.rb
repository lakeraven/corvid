# frozen_string_literal: true

require "test_helper"

class Corvid::CareTeamTest < ActiveSupport::TestCase
  TENANT = "tnt_ct_test"

  setup do
    Corvid::CareTeamMember.unscoped.delete_all
    Corvid::CareTeam.unscoped.delete_all
  end

  # =============================================================================
  # CREATION & VALIDATIONS
  # =============================================================================

  test "creates with name" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team A", facility_identifier: "fac_a")
      assert team.persisted?
    end
  end

  test "requires name" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.new(name: nil)
      refute team.valid?
      assert team.errors[:name].any?
    end
  end

  test "can have description" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(
        name: "Team A",
        facility_identifier: "fac_a",
        description: "Primary care team"
      )
      assert_equal "Primary care team", team.description
    end
  end

  test "defaults to active status" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team A", facility_identifier: "fac_a")
      assert team.active?
    end
  end

  test "can be set to inactive" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team A", facility_identifier: "fac_a")
      team.inactive!
      assert team.inactive?
    end
  end

  # =============================================================================
  # MEMBERSHIP
  # =============================================================================

  test "add_member! creates member" do
    with_tenant(TENANT) do
      team = create_team
      member = team.add_member!(role: "PCP", practitioner_identifier: "pr_001")
      assert member.persisted?
      assert_equal "PCP", member.role
    end
  end

  test "add_member! demotes any prior lead when adding a new lead" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "Lead 1", practitioner_identifier: "pr_001", lead: true)
      team.add_member!(role: "Lead 2", practitioner_identifier: "pr_002", lead: true)

      leads = team.care_team_members.where(lead: true).pluck(:practitioner_identifier)
      assert_equal ["pr_002"], leads
      assert_equal 2, team.care_team_members.count
    end
  end

  test "add_member! with lead: false preserves existing lead" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "Lead", practitioner_identifier: "pr_001", lead: true)
      team.add_member!(role: "Member", practitioner_identifier: "pr_002", lead: false)

      assert_equal "pr_001", team.lead_member.practitioner_identifier
    end
  end

  test "remove_member! removes the row for that practitioner" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "PCP", practitioner_identifier: "pr_001")
      team.add_member!(role: "Care Manager", practitioner_identifier: "pr_002")

      team.remove_member!("pr_001")
      remaining = team.care_team_members.pluck(:practitioner_identifier)
      assert_equal ["pr_002"], remaining
    end
  end

  test "active_members excludes members with past end_date" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "Active", practitioner_identifier: "pr_a")
      team.add_member!(role: "Past", practitioner_identifier: "pr_b", end_date: Date.current - 30)

      actives = team.active_members.pluck(:practitioner_identifier)
      assert_equal ["pr_a"], actives
    end
  end

  test "lead_member returns the lead" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "Lead", practitioner_identifier: "pr_001", lead: true)
      team.add_member!(role: "Member", practitioner_identifier: "pr_002")

      assert_equal "pr_001", team.lead_member.practitioner_identifier
    end
  end

  test "lead_member returns nil when no lead" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "Member", practitioner_identifier: "pr_001")
      assert_nil team.lead_member
    end
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "active_teams scope only includes status=active" do
    with_tenant(TENANT) do
      active = Corvid::CareTeam.create!(name: "Active", facility_identifier: "fac_a", status: "active")
      inactive = Corvid::CareTeam.create!(name: "Inactive", facility_identifier: "fac_a", status: "inactive")

      assert_includes Corvid::CareTeam.active_teams, active
      refute_includes Corvid::CareTeam.active_teams, inactive
    end
  end

  # =============================================================================
  # ASSOCIATIONS
  # =============================================================================

  test "has_many cases" do
    with_tenant(TENANT) do
      team = create_team
      kase = Corvid::Case.create!(patient_identifier: "pt_test", care_team: team)
      assert_includes team.cases, kase
    end
  end

  # =============================================================================
  # FHIR SERIALIZATION
  # =============================================================================

  test "to_fhir returns CareTeam resource" do
    with_tenant(TENANT) do
      team = create_team
      fhir = team.to_fhir
      assert_equal "CareTeam", fhir[:resourceType]
      assert_equal team.id.to_s, fhir[:id]
    end
  end

  test "to_fhir includes name and status" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "FHIR Team", facility_identifier: "fac_a")
      fhir = team.to_fhir
      assert_equal "FHIR Team", fhir[:name]
      assert_equal "active", fhir[:status]
    end
  end

  test "to_fhir includes participant entries" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "PCP", practitioner_identifier: "pr_001")
      team.add_member!(role: "Care Manager", practitioner_identifier: "pr_002")

      fhir = team.to_fhir
      assert_equal 2, fhir[:participant].size
    end
  end

  test "to_fhir includes managing organization" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Team", facility_identifier: "fac_a")
      fhir = team.to_fhir
      assert_equal "Organization/fac_a", fhir[:managingOrganization][0][:reference]
    end
  end

  test "to_fhir omits inactive members from participant list" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "Active", practitioner_identifier: "pr_a")
      team.add_member!(role: "Former", practitioner_identifier: "pr_b", end_date: Date.current - 1)

      participants = team.to_fhir[:participant].map { |p| p[:member][:reference] }
      assert_equal ["Practitioner/pr_a"], participants
    end
  end

  test "to_fhir participant includes role" do
    with_tenant(TENANT) do
      team = create_team
      team.add_member!(role: "PCP", practitioner_identifier: "pr_001")

      participant = team.to_fhir[:participant].first
      assert_equal "PCP", participant[:role].first[:text]
      assert_equal "Practitioner/pr_001", participant[:member][:reference]
    end
  end

  # =============================================================================
  # MULTI-TENANCY
  # =============================================================================

  test "teams scoped to tenant" do
    mine = nil
    other = nil

    with_tenant("tenant_a") do
      mine = Corvid::CareTeam.create!(name: "Mine", facility_identifier: "fac_a")
    end
    with_tenant("tenant_b") do
      other = Corvid::CareTeam.create!(name: "Other", facility_identifier: "fac_a")
    end

    with_tenant("tenant_a") do
      assert_includes Corvid::CareTeam.all, mine
      refute_includes Corvid::CareTeam.all, other
    end
  end

  private

  def create_team
    Corvid::CareTeam.create!(name: "Test Team", facility_identifier: "fac_test")
  end
end
