# frozen_string_literal: true

module Corvid
  # Adapter-backed budget facade. Real budget data lives in the EHR/CHS
  # system; this service translates Case-domain queries to adapter calls.
  #
  # Per #222 / ADR 0005: the adapter is injected per-instance rather
  # than reached via the `Corvid.adapter` global. The class-method form
  # accepts an `adapter:` kwarg (defaulting to `Corvid.adapter`) so
  # existing call sites keep working while tests and per-tenant code
  # paths can swap in their own adapters without mutating global state.
  class BudgetAvailabilityService
    DEFAULT_FISCAL_YEAR_BUDGET = 1_000_000.00
    COMMITTEE_REVIEW_THRESHOLD = 50_000.00

    def initialize(adapter: Corvid.adapter)
      @adapter = adapter
    end

    def fiscal_year_budget
      summary = @adapter.get_budget_summary
      return DEFAULT_FISCAL_YEAR_BUDGET unless summary

      (summary[:total_budget] || summary[:total]).to_f.nonzero? || DEFAULT_FISCAL_YEAR_BUDGET
    end

    def reserved_funds
      summary = @adapter.get_budget_summary
      return 0.0 unless summary

      summary[:obligated]&.to_f || 0.0
    end

    def remaining_budget
      summary = @adapter.get_budget_summary
      return 0.0 unless summary

      summary[:remaining]&.to_f || 0.0
    end

    def reserve_funds_if_available(referral_identifier, amount, params = {})
      # Adapter wire format expects a numeric amount; convert at the
      # boundary so callers can pass either a Money or a Numeric.
      numeric_amount = amount.respond_to?(:to_d) ? amount.to_d : amount
      @adapter.create_obligation(referral_identifier, numeric_amount, params)
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

    def check(referral)
      # Budget figures are still numeric (USD-equivalent dollars). Coerce
      # estimated_cost (now a Money) to BigDecimal-of-dollars so all the
      # comparisons below work without a per-call currency match check.
      # Multi-currency budgeting would belong on the tenant config when
      # we have a concrete non-USD case.
      cost = referral.estimated_cost
      cost_dollars = cost.respond_to?(:to_d) ? cost.to_d : cost
      budget = remaining_budget
      total = fiscal_year_budget

      BudgetCheckResult.new(
        funds_available: cost_dollars.present? && cost_dollars > 0 && budget >= cost_dollars,
        budget_sufficient: cost_dollars.present? && budget >= cost_dollars,
        remaining_budget: budget,
        total_budget: total,
        fiscal_year: current_fiscal_year,
        requires_cost_estimate: cost_dollars.nil? || cost_dollars <= 0,
        requires_committee_review: cost_dollars.present? && cost_dollars >= COMMITTEE_REVIEW_THRESHOLD,
        valid_funding_source: true
      )
    end

    # Class-method shims for backward compatibility. Existing callers
    # `Corvid::BudgetAvailabilityService.remaining_budget` keep working;
    # new callers pass `adapter:` to inject.
    class << self
      def fiscal_year_budget(adapter: Corvid.adapter)
        new(adapter: adapter).fiscal_year_budget
      end

      def reserved_funds(adapter: Corvid.adapter)
        new(adapter: adapter).reserved_funds
      end

      def remaining_budget(adapter: Corvid.adapter)
        new(adapter: adapter).remaining_budget
      end

      def reserve_funds_if_available(referral_identifier, amount, params = {}, adapter: Corvid.adapter)
        new(adapter: adapter).reserve_funds_if_available(referral_identifier, amount, params)
      end

      def current_quarter(adapter: Corvid.adapter)
        new(adapter: adapter).current_quarter
      end

      def check(referral, adapter: Corvid.adapter)
        new(adapter: adapter).check(referral)
      end
    end

    private

    def current_fiscal_year
      year = Date.current.year
      Date.current.month >= 10 ? "FY#{year + 1}" : "FY#{year}"
    end

    BudgetCheckResult = Struct.new(
      :funds_available, :budget_sufficient, :remaining_budget, :total_budget,
      :fiscal_year, :requires_cost_estimate, :requires_committee_review,
      :valid_funding_source,
      keyword_init: true
    ) do
      def funds_available?
        funds_available
      end

      def budget_sufficient?
        budget_sufficient
      end

      def requires_cost_estimate?
        requires_cost_estimate
      end

      def requires_committee_review?
        requires_committee_review
      end

      def valid_funding_source?
        valid_funding_source
      end
    end
  end
end
