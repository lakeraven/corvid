# frozen_string_literal: true

module Corvid
  # Creates program-specific cases (immunization, hep_b, tb, etc.) with
  # the right milestones, lifecycle, and adapter wiring.
  class ProgramTemplateService
    class << self
      def create_case(program_type:, patient_identifier:, facility_identifier: nil, anchor_date: nil, program_data: {})
        kase = Corvid::Case.create!(
          patient_identifier: patient_identifier,
          facility_identifier: facility_identifier,
          program_type: program_type,
          lifecycle_status: "intake",
          intake_at: Time.current
        )

        record_provenance(kase)
        kase
      end

      def overdue_milestones_by_program(facility_identifier:)
        cases = Corvid::Case.for_facility(facility_identifier).where.not(program_type: nil)
        case_ids = cases.pluck(:id)

        overdue_tasks = Corvid::Task.where(taskable_type: "Corvid::Case", taskable_id: case_ids)
                                    .milestones
                                    .overdue

        overdue_tasks.includes(:taskable).group_by { |t| t.taskable.program_type }
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
