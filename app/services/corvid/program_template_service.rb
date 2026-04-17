# frozen_string_literal: true

module Corvid
  # Creates program-specific cases (immunization, hep_b, tb, etc.) with
  # the right milestones, lifecycle, and adapter wiring.
  class ProgramTemplateService
    # Exposed at the class body (not inside `class << self`) so callers
    # and documentation can reference Corvid::ProgramTemplateService::MILESTONE_TEMPLATES.
    MILESTONE_TEMPLATES = {
      "tb" => [
        { key: "initial_skin_test", description: "Initial TST/IGRA test", days_after_anchor: 0, required: true },
        { key: "chest_xray", description: "Chest X-ray", days_after_anchor: 7, required: true },
        { key: "treatment_start", description: "Start treatment", days_after_anchor: 14, required: true },
        { key: "followup_6mo", description: "6-month follow-up", days_after_anchor: 180, required: true }
      ],
      "hep_b" => [
        { key: "hbig_administration", description: "HBIG administration within 12 hours", days_after_anchor: 0, required: true },
        { key: "hepb_dose_1", description: "Hep B vaccine dose 1", days_after_anchor: 0, required: true },
        { key: "hepb_dose_2", description: "Hep B vaccine dose 2", days_after_anchor: 30, required: true },
        { key: "hepb_dose_3", description: "Hep B vaccine dose 3", days_after_anchor: 180, required: true },
        { key: "post_vaccination_test", description: "Post-vaccination serology", days_after_anchor: 270, required: true }
      ],
      "immunization" => [
        { key: "review_record", description: "Review immunization record", days_after_anchor: 0, required: true },
        { key: "administer", description: "Administer vaccines", days_after_anchor: 1, required: true }
      ]
    }.freeze

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

        kase = Corvid::Case.create!(
          patient_identifier: patient_identifier,
          facility_identifier: facility_identifier,
          program_type: program_type,
          lifecycle_status: "intake",
          intake_at: Time.current,
          program_data_token: program_data_token
        )

        anchor = anchor_date || Date.current
        create_milestones(kase, program_type, anchor)
        record_provenance(kase)
        kase
      end

      def create_milestones(kase, program_type, anchor_date)
        template = MILESTONE_TEMPLATES[program_type.to_s] || []
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
