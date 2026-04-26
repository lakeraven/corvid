# frozen_string_literal: true

module Corvid
  # Read-only projections on Case-domain tables. Used by host UIs to display
  # workload metrics. No PHI in the response — only counts and aggregates.
  class CaseDashboardService
    class << self
      def summary(care_team_ids: [], provider_identifier: nil)
        metrics(care_team_ids: care_team_ids, provider_identifier: provider_identifier)
      end

      def metrics(care_team_ids:, provider_identifier:)
        cases = Corvid::Case.where(care_team_id: care_team_ids)
        active_cases = cases.active
        case_ids = cases.pluck(:id)

        my_tasks = Corvid::Task.for_assignee(provider_identifier)
                               .where(taskable_type: "Corvid::Case", taskable_id: case_ids)
        all_tasks = Corvid::Task.where(taskable_type: "Corvid::Case", taskable_id: case_ids)
        referrals = Corvid::PrcReferral.where(case_id: case_ids)

        avg_age = if active_cases.any?
          active_cases.average("EXTRACT(EPOCH FROM (NOW() - created_at)) / 86400").to_f.round(1)
        else
          0
        end

        {
          active_cases_count: active_cases.count,
          total_cases_count: cases.count,
          my_incomplete_tasks_count: my_tasks.incomplete.count,
          task_counts: task_counts(all_tasks),
          referral_pipeline: referrals.group(:status).count,
          avg_case_age_days: avg_age,
          data_source: data_source,
          generated_at: Time.current
        }
      end

      def data_source
        klass = Corvid.adapter&.class&.name.to_s
        case klass
        when /FhirAdapter/ then "FHIR"
        when /MockAdapter/ then "mock"
        when /RpmsAdapter/, /VistaAdapter/ then "RPMS"
        else "unknown"
        end
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
