# frozen_string_literal: true

require "csv"

module Corvid
  # CHS reporting reads everything from the adapter; corvid stores no
  # financial PHI of its own.
  class ChsReportingService
    class << self
      def financial_report(fiscal_year: nil)
        adapter = Corvid.adapter
        budget_summary = adapter.get_budget_summary || {}
        obligation_summary = adapter.get_obligation_summary(fiscal_year: fiscal_year)
        outstanding_obligations = adapter.get_outstanding_obligations(fiscal_year: fiscal_year)

        total_budget = (budget_summary[:total_budget] || budget_summary[:total]).to_f
        obligated = budget_summary[:obligated].to_f
        expended = budget_summary[:expended].to_f

        percent_used = total_budget > 0 ? ((obligated + expended) / total_budget * 100).round(2) : 0.0

        {
          report_type: :financial,
          generated_at: Time.current,
          fiscal_year: fiscal_year || current_fiscal_year,
          total_budget: total_budget,
          obligated: obligated,
          expended: expended,
          remaining: budget_summary[:remaining].to_f,
          percent_used: percent_used,
          obligation_summary: obligation_summary,
          outstanding_obligations: outstanding_obligations
        }
      end

      def utilization_report(from_date: nil, to_date: nil)
        referrals = Corvid::PrcReferral.all
        referrals = referrals.where("created_at >= ?", from_date) if from_date
        referrals = referrals.where("created_at <= ?", to_date) if to_date

        {
          report_type: :utilization,
          generated_at: Time.current,
          total_referrals: referrals.count,
          by_status: referrals.group(:status).count,
          by_priority: referrals.group(:medical_priority).count,
          by_provider: {},
          period: { from: from_date, to: to_date }
        }
      end

      def denial_report(from_date: nil, to_date: nil)
        referrals = Corvid::PrcReferral.all
        referrals = referrals.where("created_at >= ?", from_date) if from_date
        referrals = referrals.where("created_at <= ?", to_date) if to_date

        total = referrals.count
        denied = referrals.where(status: "denied").count
        denial_rate = total > 0 ? (denied.to_f / total * 100).round(2) : 0.0

        {
          report_type: :denial,
          generated_at: Time.current,
          total_denials: denied,
          denial_rate: denial_rate,
          by_reason: {},
          period: { from: from_date, to: to_date }
        }
      end

      def workload_report
        {
          report_type: :workload,
          generated_at: Time.current,
          pending_count: Corvid::PrcReferral.where(status: %w[submitted eligibility_review alternate_resource_review priority_assignment committee_review]).count,
          by_staff: {},
          processing_metrics: {}
        }
      end

      def to_csv(report, type: nil)
        CSV.generate do |csv|
          report.each do |key, value|
            next if value.is_a?(Hash) || value.is_a?(Array)

            csv << [key.to_s.titleize, value]
          end
        end
      end

      private

      def current_fiscal_year
        year = Date.current.year
        Date.current.month >= 10 ? "FY#{year + 1}" : "FY#{year}"
      end
    end
  end
end
