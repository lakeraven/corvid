# frozen_string_literal: true

# Task Management step definitions (ported from rpms_redux)

Given("a pending task exists") do
  @task = Corvid::Task.create!(
    taskable: @case,
    description: "Test task",
    status: :pending,
    facility_identifier: @facility
  )
end

Given("a task in progress exists") do
  @task = Corvid::Task.create!(
    taskable: @case,
    description: "Test task",
    status: :in_progress,
    facility_identifier: @facility
  )
end

Given("a task assigned to practitioner {string} exists") do |identifier|
  @task = Corvid::Task.create!(
    taskable: @case,
    description: "Assigned task",
    status: :pending,
    assignee_identifier: identifier,
    facility_identifier: @facility
  )
end

Given("a task due in {int} days exists") do |days|
  @task = Corvid::Task.create!(
    taskable: @case,
    description: "Future task",
    status: :pending,
    due_at: days.days.from_now,
    facility_identifier: @facility
  )
end

Given("a task due {int} days ago exists") do |days|
  @task = Corvid::Task.create!(
    taskable: @case,
    description: "Past task",
    status: :pending,
    due_at: days.days.ago,
    facility_identifier: @facility
  )
end

Given("a completed task due {int} days ago exists") do |days|
  @task = Corvid::Task.create!(
    taskable: @case,
    description: "Completed past task",
    status: :completed,
    due_at: days.days.ago,
    completed_at: 1.day.ago,
    facility_identifier: @facility
  )
end

Given("the following tasks exist:") do |table|
  table.hashes.each do |row|
    Corvid::Task.create!(
      taskable: @case,
      description: row["description"],
      status: row["status"].to_sym,
      facility_identifier: @facility
    )
  end
end

When("I create a task with description {string}") do |description|
  @task = Corvid::Task.create!(
    taskable: @case,
    description: description,
    facility_identifier: @facility
  )
end

When("I try to create a task without a description") do
  @task = Corvid::Task.new(
    taskable: @case,
    description: nil,
    facility_identifier: @facility
  )
  @task.valid?
end

When("I create a task with priority {string}") do |priority|
  @task = Corvid::Task.create!(
    taskable: @case,
    description: "Priority task",
    priority: priority.to_sym,
    facility_identifier: @facility
  )
end

When("I start the task") do
  @task.update!(status: :in_progress)
end

When("I complete the task") do
  @task.update!(status: :completed)
end

When("I cancel the task") do
  @task.update!(status: :cancelled)
end

When("I put the task on hold") do
  @task.update!(status: :on_hold)
end

When("I assign the task to practitioner {string}") do |identifier|
  @task.assign_to!(identifier)
end

When("I unassign the task") do
  @task.unassign!
end

When("I query for incomplete tasks") do
  @queried_tasks = Corvid::Task.incomplete
end

When("I query for overdue tasks") do
  @queried_tasks = Corvid::Task.overdue
end

When("I query for tasks due within {int} days") do |days|
  @queried_tasks = Corvid::Task.due_soon(days)
end

Then("a task should exist with description {string}") do |description|
  task = Corvid::Task.find_by(description: description)
  refute_nil task, "Expected task with description '#{description}' to exist"
end

Then("the task status should be {string}") do |expected_status|
  @task.reload
  assert_equal expected_status, @task.status
end

Then("the task should be invalid") do
  refute @task.valid?, "Expected task to be invalid"
end

Then("I should see an error about description") do
  assert_includes @task.errors[:description], "can't be blank"
end

Then("the task should have a completed_at timestamp") do
  @task.reload
  refute_nil @task.completed_at, "Expected task to have completed_at timestamp"
end

Then("the task should be assigned to practitioner {string}") do |identifier|
  @task.reload
  assert_equal identifier, @task.assignee_identifier
end

Then("the task should be unassigned") do
  @task.reload
  assert_nil @task.assignee_identifier, "Expected task to be unassigned"
end

Then("the task priority should be {string}") do |expected_priority|
  assert_equal expected_priority, @task.priority
end

Then("the task should not be overdue") do
  @task.reload
  refute @task.overdue?, "Expected task to not be overdue"
end

Then("the task should be overdue") do
  @task.reload
  assert @task.overdue?, "Expected task to be overdue"
end

Then("I should see {int} incomplete tasks") do |count|
  assert_equal count, @queried_tasks.count
end

Then("I should see {int} overdue task(s)") do |count|
  assert_equal count, @queried_tasks.count
end

Then("I should see {int} task(s) due soon") do |count|
  assert_equal count, @queried_tasks.count
end
