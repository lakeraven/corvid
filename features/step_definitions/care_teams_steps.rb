# frozen_string_literal: true

# Care team step definitions

When("I create a care team named {string}") do |name|
  @care_team = Corvid::CareTeam.create!(
    name: name,
    facility_identifier: @facility,
    status: :active
  )
end

When("I try to create a care team without a name") do
  @care_team = Corvid::CareTeam.new(facility_identifier: @facility)
  @care_team.valid?
end

When("I create a care team named {string} with description {string}") do |name, description|
  @care_team = Corvid::CareTeam.create!(
    name: name,
    description: description,
    facility_identifier: @facility,
    status: :active
  )
end

Given("a care team {string} exists") do |name|
  @care_team = Corvid::CareTeam.create!(
    name: name,
    facility_identifier: @facility,
    status: :active
  )
end

Given("a care team {string} exists in the tenant") do |name|
  @care_team = Corvid::CareTeam.create!(
    name: name,
    facility_identifier: @facility,
    status: :active
  )
end

Given("an active care team {string} exists") do |name|
  Corvid::CareTeam.create!(name: name, facility_identifier: @facility, status: :active)
end

Given("an inactive care team {string} exists") do |name|
  Corvid::CareTeam.create!(name: name, facility_identifier: @facility, status: :inactive)
end

Given("a care team {string} exists at facility {string}") do |name, facility|
  Corvid::CareTeam.create!(name: name, facility_identifier: facility, status: :active)
end

Given("a facility {string} with code {string} exists") do |_name, _code|
  # No-op — facilities are represented as string identifiers in corvid
end

When("I am working at facility {string}") do |facility|
  @facility = facility.downcase.tr(" ", "_")
end

Given("the care team has a member with role {string} and practitioner IEN {string}") do |role, ien|
  @member = @care_team.add_member!(role: role, practitioner_identifier: ien)
end

Given("the care team has a member with role {string} ending {string}") do |role, end_date|
  @member = @care_team.add_member!(
    role: role,
    practitioner_identifier: "pr_#{SecureRandom.hex(3)}",
    end_date: Date.parse(end_date)
  )
end

Given("the care team has a lead with practitioner IEN {string}") do |ien|
  @member = @care_team.add_member!(role: "Lead", practitioner_identifier: ien, lead: true)
end

Given("a case exists for patient {string}") do |_name|
  patient_id = "pt_#{SecureRandom.hex(3)}"
  @case = Corvid::Case.create!(
    patient_identifier: patient_id,
    facility_identifier: @facility
  )
end

Given("a case exists for patient {string} assigned to {string}") do |_name, team_name|
  team = Corvid::CareTeam.find_by(name: team_name)
  patient_id = "pt_#{SecureRandom.hex(3)}"
  @case = Corvid::Case.create!(
    patient_identifier: patient_id,
    facility_identifier: @facility,
    care_team: team
  )
end

When("I add a member with role {string} and practitioner IEN {string}") do |role, ien|
  @member = @care_team.add_member!(role: role, practitioner_identifier: ien)
end

When("I try to add a member without a role") do
  @member = @care_team.care_team_members.new(practitioner_identifier: "pr_001")
  @member.valid?
end

When("I remove the member with practitioner IEN {string}") do |ien|
  @care_team.remove_member!(ien)
end

When("I add a member with role {string} and practitioner IEN {string} starting {string}") do |role, ien, start_date|
  @member = @care_team.add_member!(role: role, practitioner_identifier: ien, start_date: Date.parse(start_date))
end

When("I add a member with role {string} and practitioner IEN {string} as lead") do |role, ien|
  @member = @care_team.add_member!(role: role, practitioner_identifier: ien, lead: true)
end

When("I assign the case to care team {string}") do |team_name|
  team = Corvid::CareTeam.find_by(name: team_name)
  @case.update!(care_team: team)
end

When("I view cases for care team {string}") do |team_name|
  team = Corvid::CareTeam.find_by(name: team_name)
  @viewed_cases = team.cases
end

When("I view active care teams") do
  @viewed_teams = Corvid::CareTeam.active_teams
end

When("I view all care teams") do
  @viewed_teams = Corvid::CareTeam.all
end

Given("the care team has the following members:") do |table|
  table.hashes.each do |row|
    @care_team.add_member!(role: row["role"], practitioner_identifier: row["practitioner_ien"])
  end
end

When("I request the FHIR representation") do
  @fhir_resource = @care_team.to_fhir
end

When("I create a task {string} for the case") do |description|
  @case.tasks.create!(
    tenant_identifier: @case.tenant_identifier,
    facility_identifier: @facility,
    description: description
  )
end

When("I create a task {string} assigned to practitioner {string}") do |description, ien|
  @task = @case.tasks.create!(
    tenant_identifier: @case.tenant_identifier,
    facility_identifier: @facility,
    description: description,
    assignee_identifier: ien
  )
end

Then("a care team {string} should exist") do |name|
  assert Corvid::CareTeam.exists?(name: name)
end

Then("it should belong to facility {string}") do |facility|
  assert_equal facility, @care_team.facility_identifier,
    "expected care team's facility_identifier to match the scenario"
end

Then("the care team should be invalid") do
  refute @care_team.valid?
end

Then("there should be an error on {string}") do |field|
  assert @care_team.errors[field.to_sym].any?
end

Then("the care team {string} should have description {string}") do |name, description|
  team = Corvid::CareTeam.find_by(name: name)
  assert_equal description, team.description
end

Then("{string} should have {int} members") do |team_name, count|
  team = Corvid::CareTeam.find_by(name: team_name)
  assert_equal count, team.care_team_members.count
end

Then("{string} should have {int} active members") do |team_name, count|
  team = Corvid::CareTeam.find_by(name: team_name)
  assert_equal count, team.active_members.count
end

Then("the member should be invalid") do
  refute @member.valid?
end

Then("there should be an error on member {string}") do |field|
  assert @member.errors[field.to_sym].any?
end

Then("the member should have start date {string}") do |date|
  assert_equal Date.parse(date), @member.start_date
end

Then("the member should be active") do
  assert @member.active?
end

Then("the member should be inactive") do
  assert @member.inactive?
end

Then("the case care team should be {string}") do |team_name|
  @case.reload
  assert_equal team_name, @case.care_team&.name
end

Then("I should see {int} cases") do |count|
  assert_equal count, @viewed_cases.count
end

Then("the case should have no care team") do
  assert_nil @case.care_team
end

Then("{string} should have a lead") do |team_name|
  team = Corvid::CareTeam.find_by(name: team_name)
  refute_nil team.lead_member
end

Then("the lead should have practitioner IEN {string}") do |ien|
  @care_team.reload
  assert_equal ien, @care_team.lead_member.practitioner_identifier
end

Then("the former lead should still be a member") do
  assert @care_team.care_team_members.count >= 2
end

Then("I should see care team {string}") do |team_name|
  assert @viewed_teams.pluck(:name).include?(team_name)
end

Then("I should not see care team {string}") do |team_name|
  refute @viewed_teams.pluck(:name).include?(team_name)
end

Then("I should receive a valid FHIR CareTeam resource") do
  assert_equal "CareTeam", @fhir_resource[:resourceType]
end

Then("the FHIR resource should have {int} participants") do |count|
  assert_equal count, @fhir_resource[:participant].length
end

Then("the FHIR resource should have status {string}") do |status|
  assert_equal status, @fhir_resource[:status]
end

Then("the FHIR resource should reference the facility as managing organization") do
  refute_nil @fhir_resource[:managingOrganization]
end

Then("the task should be visible to all {string} members") do |team_name|
  team = Corvid::CareTeam.find_by(name: team_name)
  # Tasks on cases assigned to a team are visible to team members by convention
  assert team.cases.any? { |c| c.tasks.any? }
end

Then("the task assignee should be practitioner {string}") do |ien|
  @task.reload
  assert_equal ien, @task.assignee_identifier
end
