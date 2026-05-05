# frozen_string_literal: true

Then("the program registry should include {string}") do |code|
  assert Corvid::ProgramRegistry.exists?(code), "expected program #{code} to be registered"
end

Given("the host registers program {string} with milestones:") do |code, table|
  milestones = table.hashes.map do |row|
    {
      key: row["key"],
      description: row["description"],
      days_after_anchor: Integer(row["days_after_anchor"]),
      required: row["required"] == "true"
    }
  end
  Corvid::ProgramRegistry.register(code, display_name: code, milestones: milestones)
end

When("I create an {string} case for patient {string} anchored on {string}") do |program_code, patient, anchor|
  @case = Corvid::ProgramTemplateService.create_case(
    program_type: program_code,
    patient_identifier: patient,
    facility_identifier: @facility,
    anchor_date: Date.parse(anchor)
  )
end

Then("the case should have milestones {string}") do |comma_list|
  expected = comma_list.split(",").map(&:strip)
  actual = @case.tasks.order(:milestone_position).pluck(:milestone_key)
  assert_equal expected, actual
end

When("I try to create a case with program type {string}") do |program_code|
  @attempted_case = Corvid::Case.new(
    patient_identifier: "pt_invalid",
    program_type: program_code
  )
  @attempted_case.valid?
end

Then("the case should be invalid with a program_type error") do
  refute @attempted_case.valid?, "expected case to be invalid"
  assert @attempted_case.errors[:program_type].any?,
         "expected program_type validation error, got: #{@attempted_case.errors.full_messages.inspect}"
end
