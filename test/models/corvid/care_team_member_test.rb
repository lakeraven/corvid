# frozen_string_literal: true

require "test_helper"

class Corvid::CareTeamMemberTest < ActiveSupport::TestCase
  TENANT = "tnt_ctm_test"

  setup do
    Corvid::CareTeamMember.unscoped.delete_all
    Corvid::CareTeam.unscoped.delete_all
  end

  # =============================================================================
  # CREATION & VALIDATIONS
  # =============================================================================

  test "creates with role and practitioner" do
    with_tenant(TENANT) do
      member = build_team.add_member!(role: "PCP", practitioner_identifier: "pr_001")
      assert member.persisted?
    end
  end

  test "role is required" do
    with_tenant(TENANT) do
      err = assert_raises(ActiveRecord::RecordInvalid) do
        build_team.care_team_members.create!(practitioner_identifier: "pr_x", role: nil)
      end
      assert_match(/Role/, err.message)
    end
  end

  test "practitioner_identifier is required" do
    with_tenant(TENANT) do
      err = assert_raises(ActiveRecord::RecordInvalid) do
        build_team.care_team_members.create!(practitioner_identifier: nil, role: "PCP")
      end
      assert_match(/Practitioner identifier/, err.message)
    end
  end

  test "practitioner is unique per team" do
    with_tenant(TENANT) do
      team = build_team
      team.add_member!(role: "PCP", practitioner_identifier: "pr_001")
      assert_raises(ActiveRecord::RecordNotUnique) do
        team.care_team_members.create!(role: "Nurse", practitioner_identifier: "pr_001")
      end
    end
  end

  test "same practitioner can be on different teams" do
    with_tenant(TENANT) do
      team1 = Corvid::CareTeam.create!(name: "Team 1", facility_identifier: "fac_a")
      team2 = Corvid::CareTeam.create!(name: "Team 2", facility_identifier: "fac_a")
      m1 = team1.add_member!(role: "PCP", practitioner_identifier: "pr_001")
      m2 = team2.add_member!(role: "Consultant", practitioner_identifier: "pr_001")
      assert m1.persisted?
      assert m2.persisted?
    end
  end

  # =============================================================================
  # ACTIVE STATUS
  # =============================================================================

  test "active? is true when end_date is nil" do
    with_tenant(TENANT) do
      member = build_team.add_member!(role: "PCP", practitioner_identifier: "pr_a")
      assert member.active?
      refute member.inactive?
    end
  end

  test "active? is true when end_date is today" do
    with_tenant(TENANT) do
      member = build_team.add_member!(
        role: "PCP", practitioner_identifier: "pr_a",
        end_date: Date.current
      )
      assert member.active?
    end
  end

  test "active? is true when end_date is in the future" do
    with_tenant(TENANT) do
      member = build_team.add_member!(
        role: "PCP", practitioner_identifier: "pr_a",
        end_date: Date.current + 30
      )
      assert member.active?
    end
  end

  test "active? is false when end_date is in the past" do
    with_tenant(TENANT) do
      member = build_team.add_member!(
        role: "Former", practitioner_identifier: "pr_x",
        end_date: Date.current - 1
      )
      refute member.active?
      assert member.inactive?
    end
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "active scope" do
    with_tenant(TENANT) do
      team = build_team
      active = team.add_member!(role: "Active", practitioner_identifier: "pr_a")
      inactive = team.add_member!(role: "Past", practitioner_identifier: "pr_b", end_date: Date.current - 1)

      assert_includes Corvid::CareTeamMember.active, active
      refute_includes Corvid::CareTeamMember.active, inactive
    end
  end

  test "inactive scope" do
    with_tenant(TENANT) do
      team = build_team
      active = team.add_member!(role: "Active", practitioner_identifier: "pr_a")
      inactive = team.add_member!(role: "Past", practitioner_identifier: "pr_b", end_date: Date.current - 1)

      refute_includes Corvid::CareTeamMember.inactive, active
      assert_includes Corvid::CareTeamMember.inactive, inactive
    end
  end

  test "leads scope" do
    with_tenant(TENANT) do
      team = build_team
      lead = team.add_member!(role: "Lead", practitioner_identifier: "pr_a", lead: true)
      member = team.add_member!(role: "Member", practitioner_identifier: "pr_b")

      assert_includes Corvid::CareTeamMember.leads, lead
      refute_includes Corvid::CareTeamMember.leads, member
    end
  end

  # =============================================================================
  # DATE RANGE
  # =============================================================================

  test "stores start_date" do
    with_tenant(TENANT) do
      member = build_team.add_member!(
        role: "PCP", practitioner_identifier: "pr_a",
        start_date: Date.new(2024, 1, 1)
      )
      assert_equal Date.new(2024, 1, 1), member.start_date
    end
  end

  test "stores end_date" do
    with_tenant(TENANT) do
      member = build_team.add_member!(
        role: "PCP", practitioner_identifier: "pr_a",
        end_date: Date.new(2024, 12, 31)
      )
      assert_equal Date.new(2024, 12, 31), member.end_date
    end
  end

  # =============================================================================
  # LEAD STATUS
  # =============================================================================

  test "lead? returns true for lead members" do
    with_tenant(TENANT) do
      member = build_team.add_member!(role: "Lead", practitioner_identifier: "pr_a", lead: true)
      assert member.lead?
    end
  end

  test "lead? defaults to false" do
    with_tenant(TENANT) do
      member = build_team.add_member!(role: "Member", practitioner_identifier: "pr_a")
      refute member.lead?
    end
  end

  private

  def build_team
    Corvid::CareTeam.create!(name: "Team", facility_identifier: "fac_a")
  end
end
