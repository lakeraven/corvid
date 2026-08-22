# frozen_string_literal: true

# Reuses the shared `a tenant {string} with facility {string}` Given from
# eligibility_checklist_steps.rb (sets @tenant, @facility, and tenant context).

Given("a migration case for patient {string}") do |pid|
  @case = Corvid.with_tenant(@tenant) do
    Corvid::Case.create!(
      patient_identifier: pid,
      facility_identifier: @facility,
      lifecycle_status: "intake"
    )
  end
end

Given("the Data Governance Board has consented to migrate {string}") do |types_str|
  types = types_str.split(",").map(&:strip)
  @consent = Corvid::Migration::BoardConsent.new(
    granted: true,
    consented_resource_types: types,
    actor_identifier: "dgb_board_001"
  )
end

Given("the Data Governance Board has not consented") do
  @consent = Corvid::Migration::BoardConsent.new(
    granted: false,
    consented_resource_types: [],
    actor_identifier: "dgb_board_001"
  )
end

def build_migration_bundle(resource_types)
  entries = resource_types.map { |t| { resource_type: t, data: { "resourceType" => t } } }
  @bundle = Corvid::MigrationBundle.new(patient_ref: @case.patient_identifier, entries: entries)
end

Given("a source bundle with a {string}, a {string}, and an {string}") do |t1, t2, t3|
  build_migration_bundle([t1, t2, t3])
end

Given("a source bundle with a {string}") do |t1|
  build_migration_bundle([t1])
end

When("the governed migration runs") do
  @target = RecordingMigrationTarget.new
  @result = Corvid.with_tenant(@tenant) do
    Corvid::GovernedMigration.new(target: @target).run(
      case_record: @case, consent: @consent, bundle: @bundle
    )
  end
end

Then("the migration succeeds") do
  assert @result.migrated?, "Expected migration to have succeeded"
end

Then("the migration halts") do
  assert @result.halted?, "Expected migration to have halted"
end

Then("an {string} determination is recorded on the case") do |outcome|
  assert_equal outcome, @case.reload.latest_determination.outcome
end

Then("a {string} determination is recorded on the case") do |outcome|
  assert_equal outcome, @case.reload.latest_determination.outcome
end

Then("the target received a {string} and a {string}") do |t1, t2|
  assert_includes @target.received_types, t1
  assert_includes @target.received_types, t2
end

Then("the target did not receive an {string}") do |t|
  refute @target.received_types.include?(t), "Expected target NOT to receive #{t}"
end

Then("no data is sent to the target") do
  assert_empty @target.received_types
  assert_empty @target.calls, "Expected reconcile! never to have been called"
end
