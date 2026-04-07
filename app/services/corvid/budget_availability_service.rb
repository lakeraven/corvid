# frozen_string_literal: true

module Corvid
  # Adapter-backed budget facade. Real budget data lives in the EHR/CHS
  # system; this service translates Case-domain queries to adapter calls.
  class BudgetAvailabilityService
    DEFAULT_FISCAL_YEAR_BUDGET = 1_000_000.00
    COMMITTEE_REVIEW_THRESHOLD = 50_000.00

    class << self
      def fiscal_year_budget
        summary = Corvid.adapter.get_budget_summary
        return DEFAULT_FISCAL_YEAR_BUDGET unless summary

        (summary[:total_budget] || summary[:total]).to_f.nonzero? || DEFAULT_FISCAL_YEAR_BUDGET
      end

      def reserved_funds
        summary = Corvid.adapter.get_budget_summary
        return 0.0 unless summary

        summary[:obligated]&.to_f || 0.0
      end

      def remaining_budget
        summary = Corvid.adapter.get_budget_summary
        return 0.0 unless summary

        summary[:remaining]&.to_f || 0.0
      end

      def reserve_funds_if_available(referral_identifier, amount, params = {})
        Corvid.adapter.create_obligation(referral_identifier, amount, params)
      end

      def current_quarter
        month = Date.current.month
        year = Date.current.year
        case month
        when 10, 11, 12 then "FY#{year + 1}-Q1"
        when 1, 2, 3 then "FY#{year}-Q2"
        when 4, 5, 6 then "FY#{year}-Q3"
        when 7, 8, 9 then "FY#{year}-Q4"
        end
      end
    end
  end
end
