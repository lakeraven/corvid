# frozen_string_literal: true

module Corvid
  # Hep B perinatal workflow — example program-specific service that
  # creates a case via ProgramTemplateService and emits provenance.
  class HepBWorkflowService
    class << self
      def create_perinatal_case(infant_identifier:, maternal_identifier:, facility_identifier:, birth_date:)
        Corvid::ProgramTemplateService.create_case(
          program_type: "hep_b",
          patient_identifier: infant_identifier,
          facility_identifier: facility_identifier,
          anchor_date: birth_date,
          program_data: { maternal_identifier: maternal_identifier }
        )
      end

      def record_milestone(kase, milestone_key, performer_identifier:, completed_at:)
        task = kase.tasks.find_by(milestone_key: milestone_key)
        return nil unless task

        task.update!(status: "completed", completed_at: completed_at)
        record_provenance(kase, milestone_key, performer_identifier)
        task
      end

      private

      def record_provenance(kase, milestone_key, performer_identifier)
        Corvid.configuration.on_provenance&.call(
          target_type: "Corvid::Case",
          target_id: kase.id.to_s,
          agent_who_identifier: performer_identifier,
          activity: "UPDATE",
          recorded: Time.current
        )
      rescue => e
        Rails.logger.error("Provenance hook failed: #{Corvid.sanitize_phi(e.message)}")
      end
    end
  end
end
