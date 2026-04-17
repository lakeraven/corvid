# frozen_string_literal: true

require "test_helper"

class Corvid::CareTeamMemberTest < ActiveSupport::TestCase
  TENANT = "tnt_ctm_test"

  setup do
    Corvid::CareTeamMember.unscoped.delete_all
    Corvid::CareTeam.unscoped.delete_all
  end

  def build_team
    Corvid::CareTeam.create!(name: "Team", facility_identifier: "fac_a")
  end

  test "active? is true when end_date is nil" do
    with_tenant(TENANT) do
      member = build_team.add_member!(role: "PCP", practitioner_identifier: "pr_a")
      assert member.active?
      refute member.inactive?
    end
  end

  test "active? is true when end_date is today or in the future" do
    with_tenant(TENANT) do
      team = build_team
      today = team.add_member!(role: "PCP", practitioner_identifier: "pr_a",
        end_date: Date.current)
      future = team.add_member!(role: "Consultant", practitioner_identifier: "pr_b",
        end_date: Date.current + 30)
      assert today.active?
      assert future.active?
    end
  end

  test "active? is false when end_date is in the past" do
    with_tenant(TENANT) do
      member = build_team.add_member!(role: "Former", practitioner_identifier: "pr_x",
        end_date: Date.current - 1)
      refute member.active?
      assert member.inactive?
    end
  end

  test "role is required" do
    with_tenant(TENANT) do
      team = build_team
      err = assert_raises(ActiveRecord::RecordInvalid) do
        team.care_team_members.create!(practitioner_identifier: "pr_x", role: nil)
      end
      assert_match(/Role/, err.message)
    end
  end
end
