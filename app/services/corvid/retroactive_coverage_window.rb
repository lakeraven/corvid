# frozen_string_literal: true

module Corvid
  # Computes the retroactive coverage window for a Medicaid application
  # under 42 U.S.C. 1396a(a)(34) as amended by H.R. 1. Window months come
  # from the member's MedicaidRuleSet, which is the state configuration
  # resolved for that member.
  #
  # Pre-2027 applications are undetermined because pre-H.R. 1 rules are
  # not configured.
  #
  # Read-only. Recording the application date, the worklist, and PRC hold
  # logic are follow-ups on #639.
  class RetroactiveCoverageWindow
    HR1_EFFECTIVE_DATE = Date.new(2027, 1, 1)

    class << self
      def for_application(application_date:, rule_set:)
        application_date = require_application_date(application_date)
        require_rule_set(rule_set)
        return not_applied(rule_set) if application_date.nil?
        return predates_hr1(rule_set) if application_date < HR1_EFFECTIVE_DATE

        months = non_negative_window_months(rule_set)
        return window_undetermined(rule_set) if months.nil?

        determined(application_date, months, rule_set)
      end

      def covers?(date_of_service:, application_date:, rule_set:)
        date_of_service = require_date(date_of_service, "date_of_service")
        application_date = require_application_date(application_date)
        window = for_application(application_date:, rule_set:)
        return unless window.status == "determined" && window.earliest_covered_date

        date_of_service >= window.earliest_covered_date
      end

      def filing_deadline(date_of_service:, rule_set:)
        date_of_service = require_date(date_of_service, "date_of_service")
        require_rule_set(rule_set)
        months = non_negative_window_months(rule_set)
        return if months.nil?

        deadline = (date_of_service >> months).end_of_month.gregorian
        deadline unless deadline < HR1_EFFECTIVE_DATE
      end

      private

      def not_applied(rule_set)
        months = non_negative_window_months(rule_set)
        reasons = [ "application_not_filed" ]
        reasons << "retroactive_window_undetermined" if months.nil?
        merged_reasons(nil, rule_set).each do |reason|
          reasons << reason unless reasons.include?(reason)
        end
        retroactive_window(
          earliest_covered_date: nil,
          window_months: months,
          status: "not_applied",
          reasons:
        )
      end

      def predates_hr1(rule_set)
        retroactive_window(
          earliest_covered_date: nil,
          window_months: nil,
          status: "undetermined",
          reasons: merged_reasons("application_predates_hr1", rule_set)
        )
      end

      def window_undetermined(rule_set)
        retroactive_window(
          earliest_covered_date: nil,
          window_months: nil,
          status: "undetermined",
          reasons: merged_reasons("retroactive_window_undetermined", rule_set)
        )
      end

      def determined(application_date, months, rule_set)
        retroactive_window(
          earliest_covered_date: (application_date << months).beginning_of_month.gregorian,
          window_months: months,
          status: "determined",
          reasons: merged_reasons(nil, rule_set)
        )
      end

      def merged_reasons(window_reason, rule_set)
        reasons = []
        reasons << window_reason if window_reason
        rule_set.reasons.each do |reason|
          reasons << reason unless reasons.include?(reason)
        end
        reasons
      end

      # Zero is a real window: the state has no retroactive coverage.
      def non_negative_window_months(rule_set)
        months = rule_set.retroactive_window_months
        months if months.is_a?(Integer) && months >= 0
      end

      def retroactive_window(earliest_covered_date:, window_months:, status:, reasons:)
        RetroactiveWindow.new(earliest_covered_date:, window_months:, status:, reasons:)
      end

      # DateTime is a Date subclass, so only an exact Date is accepted.
      # A nil application date means the application was not filed.
      def require_application_date(value)
        return if value.nil?

        require_date(value, "application_date")
      end

      def require_date(value, label)
        raise ArgumentError, "#{label} must be a Date" unless value.instance_of?(Date)

        # Julian dates are read as their Gregorian calendar day.
        value.gregorian
      end

      def require_rule_set(rule_set)
        return if rule_set.instance_of?(MedicaidRuleSet)

        raise ArgumentError, "rule_set must be a MedicaidRuleSet"
      end
    end
  end
end
