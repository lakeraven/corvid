# frozen_string_literal: true

require "test_helper"

class Corvid::CaseDashboardServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_dash_test"

  setup do
    Corvid::Task.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
    Corvid::CareTeam.unscoped.delete_all
    Corvid::CareTeamMember.unscoped.delete_all
  end

  test "service class exists" do
    assert defined?(Corvid::CaseDashboardService)
  end

  test "responds to summary" do
    with_tenant(TENANT) do
      assert Corvid::CaseDashboardService.respond_to?(:summary)
    end
  end

  # -- Metrics ---------------------------------------------------------------

  test "metrics returns active cases count" do
    with_tenant(TENANT) do
      team, provider = setup_team_and_provider
      Corvid::Case.create!(patient_identifier: "pt_1", care_team: team, facility_identifier: "fac_test")
      Corvid::Case.create!(patient_identifier: "pt_2", care_team: team, facility_identifier: "fac_test", status: :closed)

      result = Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: provider)
      assert_equal 1, result[:active_cases_count]
    end
  end

  test "metrics returns task counts by status" do
    with_tenant(TENANT) do
      team, provider = setup_team_and_provider
      kase = Corvid::Case.create!(patient_identifier: "pt_1", care_team: team, facility_identifier: "fac_test")

      Corvid::Task.create!(taskable: kase, assignee_identifier: provider, description: "Pending task", status: :pending)
      Corvid::Task.create!(taskable: kase, assignee_identifier: provider, description: "IP task", status: :in_progress)
      Corvid::Task.create!(taskable: kase, assignee_identifier: provider, description: "Done task", status: :completed)

      result = Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: provider)

      assert result.key?(:task_counts)
      assert_equal 1, result[:task_counts][:pending]
      assert_equal 1, result[:task_counts][:in_progress]
      assert_equal 1, result[:task_counts][:completed]
    end
  end

  test "metrics returns incomplete task count for provider" do
    with_tenant(TENANT) do
      team, provider = setup_team_and_provider
      kase = Corvid::Case.create!(patient_identifier: "pt_1", care_team: team, facility_identifier: "fac_test")

      Corvid::Task.create!(taskable: kase, assignee_identifier: provider, description: "Pending", status: :pending)
      Corvid::Task.create!(taskable: kase, assignee_identifier: provider, description: "In progress", status: :in_progress)
      Corvid::Task.create!(taskable: kase, assignee_identifier: provider, description: "Done", status: :completed)

      result = Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: provider)
      assert_equal 2, result[:my_incomplete_tasks_count]
    end
  end

  test "metrics returns referral pipeline grouped by state" do
    with_tenant(TENANT) do
      team, provider = setup_team_and_provider
      kase = Corvid::Case.create!(patient_identifier: "pt_1", care_team: team, facility_identifier: "fac_test")

      %w[draft submitted authorized].each_with_index do |state, i|
        ref = Corvid::PrcReferral.new(case: kase, referral_identifier: "ref_#{i}", facility_identifier: "fac_test")
        ref.status = state
        ref.save!(validate: false)
      end

      result = Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: provider)

      assert result.key?(:referral_pipeline)
      assert_equal 1, result[:referral_pipeline]["draft"]
      assert_equal 1, result[:referral_pipeline]["submitted"]
      assert_equal 1, result[:referral_pipeline]["authorized"]
    end
  end

  test "metrics includes generated_at timestamp" do
    with_tenant(TENANT) do
      team, provider = setup_team_and_provider
      result = Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: provider)

      assert result.key?(:generated_at)
      assert_kind_of Time, result[:generated_at]
    end
  end

  test "metrics returns case age statistics" do
    with_tenant(TENANT) do
      team, provider = setup_team_and_provider
      Corvid::Case.create!(patient_identifier: "pt_age", care_team: team, facility_identifier: "fac_test")

      result = Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: provider)

      assert result.key?(:avg_case_age_days)
      assert result[:avg_case_age_days] >= 0
    end
  end

  # -- Read-only guardrails --------------------------------------------------

  test "service is read-only — no records created" do
    with_tenant(TENANT) do
      team, provider = setup_team_and_provider
      Corvid::Case.create!(patient_identifier: "pt_ro", care_team: team, facility_identifier: "fac_test")

      count_before = { cases: Corvid::Case.count, tasks: Corvid::Task.count }
      Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: provider)

      assert_equal count_before[:cases], Corvid::Case.count
      assert_equal count_before[:tasks], Corvid::Task.count
    end
  end

  # -- Edge cases ------------------------------------------------------------

  test "metrics handles empty care team" do
    with_tenant(TENANT) do
      team = Corvid::CareTeam.create!(name: "Empty Team", facility_identifier: "fac_test")
      result = Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: "pr_999")

      assert_equal 0, result[:active_cases_count]
      assert_equal 0, result[:my_incomplete_tasks_count]
    end
  end

  test "tasks scoped to team cases do not leak unrelated tasks" do
    with_tenant(TENANT) do
      team, provider = setup_team_and_provider
      kase = Corvid::Case.create!(patient_identifier: "pt_1", care_team: team, facility_identifier: "fac_test")
      Corvid::Task.create!(taskable: kase, assignee_identifier: provider, description: "My task", status: :pending)
      Corvid::Task.create!(taskable: kase, assignee_identifier: provider, description: "My task 2", status: :in_progress)

      other_team = Corvid::CareTeam.create!(name: "Other Team", facility_identifier: "fac_test")
      other_case = Corvid::Case.create!(patient_identifier: "pt_other", care_team: other_team, facility_identifier: "fac_test")
      Corvid::Task.create!(taskable: other_case, assignee_identifier: provider, description: "Unrelated task", status: :pending)

      result = Corvid::CaseDashboardService.metrics(care_team_ids: [team.id], provider_identifier: provider)
      assert_equal 2, result[:my_incomplete_tasks_count]
    end
  end

  private

  def setup_team_and_provider
    provider = "pr_dash_101"
    team = Corvid::CareTeam.create!(name: "Test Team", facility_identifier: "fac_test")
    Corvid::CareTeamMember.create!(care_team: team, practitioner_identifier: provider, role: "provider")
    [team, provider]
  end
end
