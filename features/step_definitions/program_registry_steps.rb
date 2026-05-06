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
  kase = Corvid::Case.create!(patient_identifier: "pt_invalid")
  @attempted_case_program = Corvid::CaseProgram.new(
    case: kase,
    program_name: program_code,
    program_code: program_code,
    enrollment_date: Date.current
  )
  @attempted_case_program.valid?
end

Then("the case should be invalid with a program_type error") do
  refute @attempted_case_program.valid?, "expected case_program to be invalid"
  assert @attempted_case_program.errors[:program_code].any?,
         "expected program_code validation error, got: #{@attempted_case_program.errors.full_messages.inspect}"
end
