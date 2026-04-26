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

      def program_compliance_summary(program_type:, facility_identifier: nil, facility: nil)
        fac_id = facility_identifier || facility&.id&.to_s
        cases = Corvid::Case.where(program_type: program_type)
        cases = cases.for_facility(fac_id) if fac_id.present?
        case_ids = cases.pluck(:id)

        all_milestones = Corvid::Task.where(taskable_type: "Corvid::Case", taskable_id: case_ids).milestones
        completed = all_milestones.where(status: "completed")
        overdue = all_milestones.overdue

        total = all_milestones.count
        completed_count = completed.count
        rate = total > 0 ? (completed_count.to_f / total * 100).round(1) : 0.0

        {
          total_cases: cases.count,
          open_cases: cases.where.not(lifecycle_status: "closed").count,
          closed_cases: cases.where(lifecycle_status: "closed").count,
          total_milestones: total,
          completed_milestones: completed_count,
          overdue_milestones: overdue.count,
          completion_rate: rate
        }
      end
    end
  end
end
