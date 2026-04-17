# frozen_string_literal: true

# Case management dashboard step definitions (ported from rpms_redux)

Given("I am a member of {string}") do |team_name|
  # Use find_by! so a missing team from background setup raises a clear
  # RecordNotFound instead of a confusing NoMethodError on nil.add_member!
  @care_team ||= Corvid::CareTeam.find_by!(name: team_name)
  @provider_identifier = "pr_dashboard_001"
  @care_team.add_member!(role: "Care Manager", practitioner_identifier: @provider_identifier)
end

Given("there are {int} active cases for {string}") do |count, team_name|
  team = Corvid::CareTeam.find_by(name: team_name)
  count.times do |i|
    Corvid::Case.create!(
      patient_identifier: "pt_dash_active_#{i}",
      facility_identifier: @facility,
      care_team: team,
      status: :active
    )
  end
end

Given("there are {int} closed cases for {string}") do |count, team_name|
  add_closed_cases(count, team_name)
end

Given("there is {int} closed case for {string}") do |count, team_name|
  add_closed_cases(count, team_name)
end

def add_closed_cases(count, team_name)
  team = Corvid::CareTeam.find_by!(name: team_name)
  count.times do |i|
    Corvid::Case.create!(
      patient_identifier: "pt_dash_closed_#{i}",
      facility_identifier: @facility,
      care_team: team,
      status: :closed,
      closed_at: Time.current
    )
  end
end

Given("there are {int} tasks assigned to me") do |count|
  team = @care_team
  kase = Corvid::Case.where(care_team: team).first ||
         Corvid::Case.create!(
           patient_identifier: "pt_task_holder",
           facility_identifier: @facility,
           care_team: team
         )
  count.times do |i|
    kase.tasks.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      description: "Assigned task #{i}",
      assignee_identifier: @provider_identifier
    )
  end
end

Given("there are referrals in various states for {string}") do |team_name|
  team = Corvid::CareTeam.find_by(name: team_name)
  %w[submitted eligibility_review authorized denied].each_with_index do |state, i|
    kase = Corvid::Case.create!(
      patient_identifier: "pt_pipeline_#{i}",
      facility_identifier: @facility,
      care_team: team
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "rf_pipe_#{i}",
      facility_identifier: @facility,
      status: state
    )
  end
end

When("I view the case management dashboard") do
  @dashboard_metrics = Corvid::CaseDashboardService.metrics(
    care_team_ids: [@care_team.id],
    provider_identifier: @provider_identifier
  )
end

When("I view the case management dashboard filtered by {string}") do |status|
  team = @care_team
  @filtered_cases = Corvid::Case.where(care_team: team, status: status)
end

When("the CaseDashboardService computes metrics") do
  @dashboard_metrics = Corvid::CaseDashboardService.metrics(
    care_team_ids: [@care_team.id],
    provider_identifier: @provider_identifier
  )
end

Then("I should see active case count of {int}") do |count|
  assert_equal count, @dashboard_metrics[:active_cases_count]
end

Then("I should see task count of {int}") do |count|
  assert_equal count, @dashboard_metrics[:my_incomplete_tasks_count]
end

Then("I should see the referral pipeline grouped by state") do
  refute_nil @dashboard_metrics[:referral_pipeline]
  assert @dashboard_metrics[:referral_pipeline].any?
end

Then("I should see only active cases") do
  @filtered_cases.each { |c| assert_equal "active", c.status }
end

Then("the dashboard should indicate data is sourced from RPMS") do
  refute_nil @dashboard_metrics[:generated_at]
  refute_nil @dashboard_metrics[:data_source],
    "dashboard metrics should carry a data_source field"
end

Then("the metrics should include active case count") do
  refute_nil @dashboard_metrics[:active_cases_count]
end

Then("the metrics should include referral pipeline counts") do
  refute_nil @dashboard_metrics[:referral_pipeline]
end

Then("the service should be read-only with no side effects") do
  # Dashboard metrics is a pure read — no records created/updated
  count_before = Corvid::Case.count
  Corvid::CaseDashboardService.metrics(
    care_team_ids: [@care_team.id],
    provider_identifier: @provider_identifier
  )
  assert_equal count_before, Corvid::Case.count
end
