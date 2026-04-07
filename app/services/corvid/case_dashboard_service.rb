# frozen_string_literal: true

module Corvid
  # Read-only projections on Case-domain tables. Used by host UIs to display
  # workload metrics. No PHI in the response — only counts and aggregates.
  class CaseDashboardService
    class << self
      def metrics(care_team_ids:, provider_identifier:)
        cases = Corvid::Case.where(care_team_id: care_team_ids)
        active_cases = cases.active
        case_ids = cases.pluck(:id)

        my_tasks = Corvid::Task.for_assignee(provider_identifier)
                               .where(taskable_type: "Corvid::Case", taskable_id: case_ids)
        all_tasks = Corvid::Task.where(taskable_type: "Corvid::Case", taskable_id: case_ids)
        referrals = Corvid::PrcReferral.where(case_id: case_ids)

        {
          active_cases_count: active_cases.count,
          total_cases_count: cases.count,
          my_incomplete_tasks_count: my_tasks.incomplete.count,
          task_counts: task_counts(all_tasks),
          referral_pipeline: referrals.group(:status).count,
          generated_at: Time.current
        }
      end

      private

      def task_counts(tasks)
        counts = tasks.group(:status).count
        Corvid::Task.statuses.each_key { |s| counts[s] ||= 0 }
        counts.transform_keys(&:to_sym)
      end
    end
  end
end
