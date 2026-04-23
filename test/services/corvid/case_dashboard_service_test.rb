# frozen_string_literal: true

require "test_helper"

class Corvid::CaseDashboardServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_dash_test"

  setup do
    Corvid::Task.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::CareTeamMember.unscoped.delete_all
    Corvid::CareTeam.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # METRICS
  # =============================================================================

  test "metrics returns active cases count" do
    with_tenant(TENANT) do
      team = create_team
      create_case(care_team: team)
      create_case(care_team: team)
      closed = create_case(care_team: team)
      closed.closed!

      result = Corvid::CaseDashboardService.metrics(
        care_team_ids: [team.id],
        provider_identifier: "pr_001"
      )

      assert_equal 2, result[:active_cases_count]
      assert_equal 3, result[:total_cases_count]
    end
  end

  test "metrics returns task counts by status" do
    with_tenant(TENANT) do
      team = create_team
      kase = create_case(care_team: team)

      Corvid::Task.create!(taskable: kase, description: "Pending task")
      ip = Corvid::Task.create!(taskable: kase, description: "In progress task")
      ip.in_progress!
      done = Corvid::Task.create!(taskable: kase, description: "Done task")
      done.completed!

      result = Corvid::CaseDashboardService.metrics(
        care_team_ids: [team.id],
        provider_identifier: "pr_001"
      )

      assert_equal 1, result[:task_counts][:pending]
      assert_equal 1, result[:task_counts][:in_progress]
      assert_equal 1, result[:task_counts][:completed]
    end
  end

  test "metrics returns incomplete task count for provider" do
    with_tenant(TENANT) do
      team = create_team
      kase = create_case(care_team: team)

      my_task = Corvid::Task.create!(taskable: kase, description: "My task")
      my_task.assign_to!("pr_001")
      other_task = Corvid::Task.create!(taskable: kase, description: "Other task")
      other_task.assign_to!("pr_002")

      result = Corvid::CaseDashboardService.metrics(
        care_team_ids: [team.id],
        provider_identifier: "pr_001"
      )

      assert_equal 1, result[:my_incomplete_tasks_count]
    end
  end

  test "metrics returns referral pipeline grouped by status" do
    with_tenant(TENANT) do
      team = create_team
      kase = create_case(care_team: team)

      Corvid::PrcReferral.create!(case: kase, referral_identifier: "ref_1")
      r2 = Corvid::PrcReferral.create!(case: kase, referral_identifier: "ref_2")
      r2.submit!

      result = Corvid::CaseDashboardService.metrics(
        care_team_ids: [team.id],
        provider_identifier: "pr_001"
      )

      assert result[:referral_pipeline].key?("draft")
      assert result[:referral_pipeline].key?("submitted")
    end
  end

  test "metrics includes generated_at timestamp" do
    with_tenant(TENANT) do
      team = create_team

      result = Corvid::CaseDashboardService.metrics(
        care_team_ids: [team.id],
        provider_identifier: "pr_001"
      )

      assert_not_nil result[:generated_at]
    end
  end

  # =============================================================================
  # DATA SOURCE
  # =============================================================================

  test "data_source returns mock for MockAdapter" do
    assert_equal "mock", Corvid::CaseDashboardService.data_source
  end

  # =============================================================================
  # EDGE CASES
  # =============================================================================

  test "metrics with empty care team returns zeroes" do
    with_tenant(TENANT) do
      team = create_team

      result = Corvid::CaseDashboardService.metrics(
        care_team_ids: [team.id],
        provider_identifier: "pr_001"
      )

      assert_equal 0, result[:active_cases_count]
      assert_equal 0, result[:total_cases_count]
      assert_equal 0, result[:my_incomplete_tasks_count]
    end
  end

  test "metrics scopes tasks to given care teams only" do
    with_tenant(TENANT) do
      team1 = create_team
      team2 = Corvid::CareTeam.create!(name: "Other Team", facility_identifier: "fac_test")

      case1 = create_case(care_team: team1)
      case2 = create_case(care_team: team2)

      Corvid::Task.create!(taskable: case1, description: "Team 1 task")
      Corvid::Task.create!(taskable: case2, description: "Team 2 task")

      result = Corvid::CaseDashboardService.metrics(
        care_team_ids: [team1.id],
        provider_identifier: "pr_001"
      )

      assert_equal 1, result[:total_cases_count]
    end
  end

  private

  def create_team
    Corvid::CareTeam.create!(name: "Dashboard Team", facility_identifier: "fac_test")
  end

  def create_case(care_team: nil)
    Corvid::Case.create!(
      patient_identifier: "pt_dash_#{SecureRandom.hex(4)}",
      lifecycle_status: "intake",
      facility_identifier: "fac_test",
      care_team: care_team
    )
  end
end
