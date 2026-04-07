# frozen_string_literal: true

module Corvid
  # Audit-ready timelines for program cases. Reads provenance via the
  # configured fetch_provenance hook (per ADR 0002).
  class ProgramCaseAuditService
    class << self
      def case_timeline(kase)
        entries = []

        # Milestones from local task records
        kase.tasks.where.not(milestone_key: nil).order(:milestone_position).each do |task|
          entries << {
            type: "milestone",
            milestone_key: task.milestone_key,
            description: task.description,
            status: task.status,
            timestamp: task.completed_at || task.due_at
          }
        end

        # Provenance from host via hook
        provenances = Corvid.configuration.fetch_provenance.call(
          target_type: "Corvid::Case", target_id: kase.id.to_s
        ) || []
        provenances.each do |prov|
          entries << {
            type: "provenance",
            activity: prov[:activity] || prov["activity"],
            recorded: prov[:recorded] || prov["recorded"],
            timestamp: prov[:recorded] || prov["recorded"]
          }
        end

        entries.sort_by { |e| e[:timestamp] || Time.at(0) }
      end

      def program_compliance_summary(program_type:, facility_identifier:)
        cases = Corvid::Case.for_facility(facility_identifier).where(program_type: program_type)
        case_ids = cases.pluck(:id)

        all_milestones = Corvid::Task.where(taskable_type: "Corvid::Case", taskable_id: case_ids).milestones
        completed = all_milestones.where(status: "completed")

        {
          total_cases: cases.count,
          open_cases: cases.where.not(lifecycle_status: "closed").count,
          closed_cases: cases.where(lifecycle_status: "closed").count,
          total_milestones: all_milestones.count,
          completed_milestones: completed.count
        }
      end
    end
  end
end
