# frozen_string_literal: true

module Corvid
  # Creates program-specific cases (immunization, hep_b, tb, plus any
  # host-registered programs) with the right milestones, lifecycle, and
  # adapter wiring. Milestone templates live on Corvid::ProgramRegistry —
  # registering a new program automatically gives it a milestone ladder
  # without engine changes.
  class ProgramTemplateService
    class << self
      def create_case(program_type:, patient_identifier:, facility_identifier: nil, anchor_date: nil, program_data: {})
        # Per ADR 0003, program_data is tokenized before persistence —
        # Case.program_data_token holds a vault token, never raw payload.
        program_data_token = if program_data.present?
          Corvid.adapter.store_text(
            case_token: "program-data-pending",
            kind: :note,
            text: program_data.to_json
          )
        end

        anchor = anchor_date || Date.current
        program = Corvid::ProgramRegistry.find(program_type)

        kase = Corvid::Case.transaction do
          k = Corvid::Case.create!(
            patient_identifier: patient_identifier,
            facility_identifier: facility_identifier,
            lifecycle_status: "intake",
            intake_at: Time.current,
            program_data_token: program_data_token
          )
          Corvid::CaseProgram.create!(
            case: k,
            program_code: program_type,
            program_name: program&.display_name || program_type,
            enrollment_date: anchor
          )
          k
        end

        create_milestones(kase, program_type, anchor)
        record_provenance(kase)
        kase
      end

      def create_milestones(kase, program_type, anchor_date)
        program = Corvid::ProgramRegistry.find(program_type)
        template = program ? program.milestones : []
        template.each_with_index do |milestone, idx|
          kase.tasks.create!(
            tenant_identifier: kase.tenant_identifier,
            facility_identifier: kase.facility_identifier,
            description: milestone[:description],
            milestone_key: milestone[:key],
            milestone_position: idx,
            required: milestone[:required],
            due_at: anchor_date + milestone[:days_after_anchor].days,
            priority: :routine
          )
        end
      end

      def overdue_milestones_by_program(facility_identifier:)
        cases = Corvid::Case.for_facility(facility_identifier).joins(:case_programs).distinct
        case_ids = cases.pluck(:id)

        overdue_tasks = Corvid::Task.where(taskable_type: "Corvid::Case", taskable_id: case_ids)
                                    .milestones
                                    .overdue

        overdue_tasks.includes(taskable: :case_programs).group_by do |t|
          t.taskable.case_programs.first&.program_code
        end
      end

      private

      def record_provenance(kase)
        Corvid.configuration.on_provenance&.call(
          target_type: "Corvid::Case",
          target_id: kase.id.to_s,
          activity: "CREATE",
          recorded: Time.current
        )
      rescue => e
        Rails.logger.error("Provenance hook failed: #{Corvid.sanitize_phi(e.message)}")
      end
    end
  end
end
