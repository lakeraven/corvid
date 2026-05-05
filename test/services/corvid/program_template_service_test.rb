# frozen_string_literal: true

require "test_helper"

class Corvid::ProgramTemplateServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_pt_test"

  test "create_case materializes the TB milestone ladder" do
    with_tenant(TENANT) do
      kase = Corvid::ProgramTemplateService.create_case(
        program_type: "tb",
        patient_identifier: "pt_tb_001",
        facility_identifier: "fac_a",
        anchor_date: Date.new(2026, 1, 1)
      )
      milestones = kase.tasks.order(:milestone_position).pluck(:milestone_key)
      assert_equal %w[initial_skin_test chest_xray treatment_start followup_6mo],
        milestones
    end
  end

  test "create_case anchors milestones to provided anchor_date" do
    with_tenant(TENANT) do
      anchor = Date.new(2026, 1, 1)
      kase = Corvid::ProgramTemplateService.create_case(
        program_type: "hep_b",
        patient_identifier: "pt_hb_001",
        anchor_date: anchor
      )
      post_vac = kase.tasks.find_by(milestone_key: "post_vaccination_test")
      # Template says days_after_anchor: 270
      assert_equal anchor + 270, post_vac.due_at.to_date
    end
  end

  test "overdue_milestones_by_program groups overdue required milestones by program" do
    with_tenant(TENANT) do
      # Anchor in the past so some milestones are overdue today
      Corvid::ProgramTemplateService.create_case(
        program_type: "tb",
        patient_identifier: "pt_ov_001",
        facility_identifier: "fac_a",
        anchor_date: Date.current - 400
      )
      Corvid::ProgramTemplateService.create_case(
        program_type: "hep_b",
        patient_identifier: "pt_ov_002",
        facility_identifier: "fac_a",
        anchor_date: Date.current - 400
      )

      result = Corvid::ProgramTemplateService.overdue_milestones_by_program(
        facility_identifier: "fac_a"
      )
      assert result.key?("tb"), "expected tb bucket in #{result.keys.inspect}"
      assert result.key?("hep_b"), "expected hep_b bucket in #{result.keys.inspect}"
      assert result["tb"].any?, "expected at least one overdue TB milestone"
      result["tb"].each { |t| assert_equal "Corvid::Case", t.taskable_type }
    end
  end

  test "create_case materializes milestones for host-registered programs" do
    Corvid::ProgramRegistry.register(
      "access_bh",
      display_name: "ACCESS Behavioral Health",
      milestones: [
        { key: "initial_phq9", description: "Initial PHQ-9", days_after_anchor: 0, required: true },
        { key: "followup_phq9_30d", description: "30-day PHQ-9", days_after_anchor: 30, required: true }
      ]
    )

    with_tenant(TENANT) do
      kase = Corvid::ProgramTemplateService.create_case(
        program_type: "access_bh",
        patient_identifier: "pt_access_001",
        facility_identifier: "fac_a",
        anchor_date: Date.new(2026, 1, 1)
      )
      milestones = kase.tasks.order(:milestone_position).pluck(:milestone_key)
      assert_equal %w[initial_phq9 followup_phq9_30d], milestones
    end
  ensure
    Corvid::ProgramRegistry.reset!
  end
end
