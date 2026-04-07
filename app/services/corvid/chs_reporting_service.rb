# frozen_string_literal: true

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

      private

      def current_fiscal_year
        year = Date.current.year
        Date.current.month >= 10 ? "FY#{year + 1}" : "FY#{year}"
      end
    end
  end
end
