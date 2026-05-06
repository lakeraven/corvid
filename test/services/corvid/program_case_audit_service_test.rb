# frozen_string_literal: true

require "test_helper"

class Corvid::ProgramCaseAuditServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_audit_test"

  test "service class exists" do
    assert defined?(Corvid::ProgramCaseAuditService)
  end

  # -- case_timeline ---------------------------------------------------------

  test "case_timeline returns ordered milestone entries" do
    with_tenant(TENANT) do
      kase = create_program_case("pt_timeline", "hep_b")
      Corvid::Task.create!(taskable: kase, description: "First dose", milestone_key: "first_dose", milestone_position: 1, due_at: 1.week.from_now)
      completed_task = Corvid::Task.create!(taskable: kase, description: "Intake", milestone_key: "intake", milestone_position: 0, due_at: 1.day.ago)
      completed_task.completed!

      timeline = Corvid::ProgramCaseAuditService.case_timeline(kase)

      assert timeline.is_a?(Array)
      assert timeline.any?
      assert timeline.first.key?(:milestone_key)
      assert timeline.first.key?(:status)
    end
  end

  # -- program_compliance_summary --------------------------------------------

  test "program_compliance_summary returns completion rates and overdue counts" do
    with_tenant(TENANT) do
      kase1 = create_program_case("pt_comp1", "hep_b")
      Corvid::Task.create!(taskable: kase1, description: "Dose 1", milestone_key: "dose_1", milestone_position: 1, due_at: 1.year.ago, status: :pending)

      kase2 = create_program_case("pt_comp2", "hep_b")
      t = Corvid::Task.create!(taskable: kase2, description: "Dose 1", milestone_key: "dose_1", milestone_position: 1, due_at: 1.month.from_now)
      t.completed!

      summary = Corvid::ProgramCaseAuditService.program_compliance_summary(
        program_type: "hep_b",
        facility_identifier: "fac_test"
      )

      assert summary.key?(:total_cases)
      assert summary.key?(:open_cases)
      assert summary.key?(:closed_cases)
      assert summary.key?(:total_milestones)
      assert summary.key?(:completed_milestones)
      assert summary.key?(:overdue_milestones)
      assert summary.key?(:completion_rate)
      assert_equal 2, summary[:total_cases]
    end
  end

  test "program_compliance_summary for facility with no cases returns zeroes" do
    with_tenant(TENANT) do
      summary = Corvid::ProgramCaseAuditService.program_compliance_summary(
        program_type: "tb",
        facility_identifier: "fac_empty"
      )

      assert_equal 0, summary[:total_cases]
      assert_equal 0, summary[:total_milestones]
      assert_equal 0.0, summary[:completion_rate]
    end
  end

  private

  def create_program_case(patient_identifier, program_code)
    kase = Corvid::Case.create!(
      patient_identifier: patient_identifier, facility_identifier: "fac_test"
    )
    Corvid::CaseProgram.create!(
      case: kase, program_name: program_code.titleize,
      program_code: program_code, enrollment_date: Date.current
    )
    kase
  end
end
