# frozen_string_literal: true

# Public health case tracking (ported from rpms_redux)

When("I create a TB case for patient {string} anchored on {string}") do |patient_id, anchor|
  @case = Corvid::ProgramTemplateService.create_case(
    program_type: "tb",
    patient_identifier: patient_id,
    facility_identifier: @facility,
    anchor_date: Date.parse(anchor)
  )
end

Given("a Hep B perinatal case exists for infant {string} with mother {string} born {string}") do |infant, mother, birth|
  @case = Corvid::HepBWorkflowService.create_perinatal_case(
    infant_identifier: infant,
    maternal_identifier: mother,
    facility_identifier: @facility,
    birth_date: Date.parse(birth)
  )
end

When("I record HBIG administration by provider {string}") do |provider_id|
  Corvid::HepBWorkflowService.record_milestone(
    @case, "hbig_administration",
    performer_identifier: provider_id,
    completed_at: Time.current
  )
end

When("all required milestones are completed") do
  @case.tasks.where(required: true).update_all(status: "completed", completed_at: Time.current)
end

When("I try to close the case") do
  @case.update!(lifecycle_status: "closed", status: "closed", closed_at: Time.current)
end

When("I request the audit timeline") do
  @audit_timeline = @case.tasks.milestones.order(:milestone_position).map do |task|
    { milestone_key: task.milestone_key,
      status: task.status,
      due_at: task.due_at,
      completed_at: task.completed_at }
  end
end

Then("a program case should exist for patient {string} with type {string}") do |patient_id, type|
  kase = Corvid::Case.find_by(patient_identifier: patient_id, program_type: type)
  refute_nil kase
end

Then("the case should have milestones from the TB template") do
  milestones = @case.tasks.milestones
  assert milestones.count >= 3
end

Then("the {string} milestone should be completed") do |key|
  task = @case.tasks.find_by(milestone_key: key)
  refute_nil task
  assert_equal "completed", task.status
end

Then("the case should have overdue milestones") do
  overdue = @case.tasks.milestones.overdue
  assert overdue.any?, "Expected overdue milestones but found none"
end

Then("the case lifecycle status should be {string}") do |status|
  @case.reload
  assert_equal status, @case.lifecycle_status
end

Then("I should receive an ordered list of milestone entries") do
  refute_nil @audit_timeline
  assert @audit_timeline.length >= 1
end
