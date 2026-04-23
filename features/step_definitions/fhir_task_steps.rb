# frozen_string_literal: true

def create_task_case
  @task_case ||= Corvid::Case.create!(
    patient_identifier: "pt_fhir_task",
    lifecycle_status: "intake",
    facility_identifier: @facility || "fac_test"
  )
end

Given("a task exists with status {string}") do |status|
  @task = Corvid::Task.create!(
    taskable: create_task_case,
    description: "Test task",
    status: status
  )
end

Given("a task exists with description {string}") do |desc|
  @task = Corvid::Task.create!(
    taskable: create_task_case,
    description: desc
  )
end

Given("an urgent task exists") do
  @task = Corvid::Task.create!(
    taskable: create_task_case,
    description: "Urgent task",
    priority: :urgent
  )
end

Given("a task exists on a case") do
  @task = Corvid::Task.create!(
    taskable: create_task_case,
    description: "Case task"
  )
end

Given("a task exists on a referral") do
  referral = Corvid::PrcReferral.create!(
    case: create_task_case,
    referral_identifier: "ref_#{SecureRandom.hex(4)}"
  )
  @task = Corvid::Task.create!(
    taskable: referral,
    description: "Referral task"
  )
end

Given("a task exists assigned to {string}") do |assignee|
  @task = Corvid::Task.create!(
    taskable: create_task_case,
    description: "Assigned task"
  )
  @task.assign_to!(assignee)
end

Given("a task exists due in {int} days") do |days|
  @task = Corvid::Task.create!(
    taskable: create_task_case,
    description: "Due task",
    due_at: days.days.from_now
  )
end

Given("tasks exist with all five statuses") do
  @status_tasks = %w[pending in_progress completed cancelled on_hold].map do |status|
    Corvid::Task.create!(
      taskable: create_task_case,
      description: "#{status} task",
      status: status
    )
  end
end

When("I serialize the task to FHIR") do
  @fhir = @task.to_fhir
end

When("I serialize and parse each task") do
  @round_trips = @status_tasks.map do |task|
    fhir = task.to_fhir
    fhir_os = OpenStruct.new(status: fhir[:status])
    parsed = Corvid::Task.from_fhir_attributes(fhir_os)
    { original: task.status, parsed: parsed[:status] }
  end
end

Then("the FHIR task status should be {string}") do |status|
  assert_equal status, @fhir[:status]
end

Then("the FHIR resourceType should be {string}") do |type|
  assert_equal type, @fhir[:resourceType]
end

Then("the FHIR task intent should be {string}") do |intent|
  assert_equal intent, @fhir[:intent]
end

Then("the FHIR task priority should be {string}") do |priority|
  assert_equal priority, @fhir[:priority]
end

Then("the FHIR task description should be {string}") do |desc|
  assert_equal desc, @fhir[:description]
end

Then("the FHIR task focus should reference {string}") do |type|
  assert @fhir[:focus].present?
  assert_includes @fhir[:focus][:reference], "#{type}/"
end

Then("the FHIR task owner should reference {string}") do |ref|
  assert @fhir[:owner].present?
  assert_includes @fhir[:owner][:reference], ref
end

Then("the FHIR task should have no owner") do
  assert_nil @fhir[:owner]
end

Then("the FHIR task should have executionPeriod") do
  assert @fhir[:executionPeriod].present?
end

Then("the FHIR task should not have executionPeriod") do
  assert_nil @fhir[:executionPeriod]
end

Then("the FHIR task should have authoredOn") do
  assert @fhir[:authoredOn].present?
end

Then("the FHIR task should have lastModified") do
  assert @fhir[:lastModified].present?
end

Then("each round-trip should preserve the original status") do
  @round_trips.each do |rt|
    assert_equal rt[:original], rt[:parsed],
      "Round-trip failed: #{rt[:original]} → #{rt[:parsed]}"
  end
end
