# frozen_string_literal: true

require "bigdecimal"
require "date"

module Corvid
  module Rcm
    # Real-time eligibility shapes for the clearinghouse port (X12 271).
    #
    # These are in-memory boundary values, like Claim and Remittance: no
    # ActiveRecord, no persistence. Unknown is never a no. An explicit
    # inactive answer stays `:inactive` unless a stated window contains the
    # service date or the eligibility date is a different day. An error, a
    # timeout, a payer mismatch, or any unmapped answer is `:undetermined`
    # (42 CFR 136.61). A coverage benefit answers only for a service type
    # the inquiry asked for. An active answer whose most restrictive
    # coverage window does not contain the service date is `:undetermined`.
    # A present inquiry payer has to match every contributing plan.
    #
    # EB01 codes that are an explicit coverage answer. "1" is active coverage.
    # "6" is inactive. The other active and inactive variants (2–5, 7, 8) are
    # not a clear yes or no, and a benefit such as a copay (B) or coinsurance
    # (A) does not answer the coverage question by itself. A coverage EB with
    # no service type is health benefit plan coverage ("30") and counts only
    # when that service type was asked.
    ACTIVE_COVERAGE_CODE = "1"
    INACTIVE_COVERAGE_CODE = "6"

    ELIGIBILITY_OUTCOMES = %i[active inactive undetermined].freeze

    # X12 271 service type 30: Health Benefit Plan Coverage. A coverage EB
    # with a nil or blank service type is this code.
    HEALTH_BENEFIT_PLAN_COVERAGE = "30"

    # Default inquiry service type when the caller does not name one.
    DEFAULT_SERVICE_TYPE_CODES = [ HEALTH_BENEFIT_PLAN_COVERAGE ].freeze

    # One eligibility question. Identifiers are opaque tokens (ADR 0003).
    # `member_identifier` may be nil when the caller does not have one; that
    # is an undetermined check, not an inactive one. `service_date` is nil
    # or a Date, including a subclass of Date. It is normalised with
    # `to_date`: a Date stays as it is, and a DateTime becomes the plain
    # Date for that day. Anything else raises ArgumentError with a fixed
    # message.
    EligibilityInquiry = Data.define(
      :patient_identifier,
      :payer_identifier,
      :member_identifier,
      :service_date,
      :service_type_codes,
      :provider_npi
    ) do
      SERVICE_DATE_ERROR = "service_date must be a Date or nil"

      def initialize(patient_identifier:, payer_identifier:, service_date:, provider_npi:,
                     member_identifier: nil, service_type_codes: DEFAULT_SERVICE_TYPE_CODES)
        super(
          patient_identifier: patient_identifier,
          payer_identifier: payer_identifier,
          member_identifier: member_identifier,
          service_date: normalize_service_date(service_date),
          service_type_codes: Array(service_type_codes).dup.freeze,
          provider_npi: provider_npi
        )
        freeze
      end

      private

      # `Date#to_date` returns itself. `DateTime#to_date` returns the civil
      # day as a plain Date. Nil is allowed. Anything that is not a Date
      # is refused before `to_date` is called.
      def normalize_service_date(service_date)
        return nil if service_date.nil?
        raise ArgumentError, SERVICE_DATE_ERROR unless service_date.is_a?(Date)

        service_date.to_date
      end
    end

    # One EB benefit. `code` is EB01, `coverage_level` is EB02, `amount` is
    # EB07, `percent` is EB08, and `in_network` is EB12 (Y/N; W and U are nil).
    EligibilityBenefit = Data.define(
      :service_type_code,
      :code,
      :coverage_level,
      :amount,
      :percent,
      :in_network
    ) do
      def initialize(service_type_code:, code:, coverage_level: nil, amount: nil, percent: nil,
                     in_network: nil)
        super
        freeze
      end
    end

    # One AAA reject. `code` is AAA03, `followup_action` is AAA04.
    EligibilityError = Data.define(:code, :description, :followup_action) do
      def initialize(code:, description:, followup_action: nil)
        super
        freeze
      end
    end

    # The plan-date span one subscriber or dependent loop stated.
    # `start_date` is the earliest start and `end_date` is the latest end
    # among that loop's plan-date segments, other than a D8 eligibility
    # day. Either may be nil: the side was omitted, or it was a year-9999
    # placeholder. A nil side is open. This is wider than the most
    # restrictive bounds on `EligibilityPlan`.
    EligibilityWindow = Data.define(:start_date, :end_date) do
      def initialize(start_date: nil, end_date: nil)
        super
        freeze
      end
    end

    # Coverage for one plan on the 271. `coverage_start` and `coverage_end`
    # are the most restrictive bounds (latest start, earliest end). They
    # gate an `:active` answer. A year-9999 date is open-ended and is
    # stored as nil — payers use 9999-12-31 (and nearby days) as a
    # placeholder, not as a real termination.
    #
    # `stated_windows` is one `EligibilityWindow` per subscriber or selected
    # dependent loop that stated plan dates. The default is an empty frozen
    # array. `eligibility_date` is the D8 307 day when the response stated
    # one, otherwise nil. That day also pins `coverage_start` and
    # `coverage_end` when it lies inside the other plan bounds. An inactive
    # answer is `:undetermined` when a stated window contains the service
    # date, or when `eligibility_date` is present and is not that date.
    EligibilityPlan = Data.define(
      :payer_identifier,
      :plan_name,
      :group_number,
      :coverage_start,
      :coverage_end,
      :benefits,
      :stated_windows,
      :eligibility_date
    ) do
      def initialize(payer_identifier:, plan_name: nil, group_number: nil, coverage_start: nil,
                     coverage_end: nil, benefits: [], stated_windows: [], eligibility_date: nil)
        super(
          payer_identifier: payer_identifier,
          plan_name: plan_name,
          group_number: group_number,
          coverage_start: coverage_start,
          coverage_end: coverage_end,
          benefits: Array(benefits).dup.freeze,
          stated_windows: Array(stated_windows).dup.freeze,
          eligibility_date: eligibility_date
        )
        freeze
      end

      # CCYYMMDD or CCYY-MM-DD. Blank, a year-9999 placeholder, and an
      # impossible calendar day are nil. Nothing here raises. The 271 reader
      # does not use this for plan dates: a year-9999 placeholder is
      # open-ended, and a present unreadable value is a malformed file.
      def self.coverage_date(raw)
        digits = coverage_digits(raw.to_s.strip)
        return nil if digits.nil? || digits.start_with?("9999")

        Date.strptime(digits, "%Y%m%d")
      rescue Date::Error
        nil
      end

      def self.coverage_digits(text)
        return text if text.match?(/\A\d{8}\z/)
        return text.delete("-") if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        nil
      end
      private_class_method :coverage_digits
    end

    # The answer to one eligibility check. `as_of` is when *this* client
    # answered, from its clock — not a date copied out of the 271. `raw_reference`
    # is an opaque pointer back at the raw 271 for the adapter that has one;
    # it is nil when there is nothing to point at.
    EligibilityResponse = Data.define(
      :outcome,
      :plans,
      :errors,
      :as_of,
      :raw_reference
    ) do
      def initialize(outcome:, plans: [], errors: [], as_of: nil, raw_reference: nil)
        unless ELIGIBILITY_OUTCOMES.include?(outcome)
          raise ArgumentError, "unknown eligibility outcome #{outcome.inspect}"
        end

        super(
          outcome: outcome,
          plans: Array(plans).dup.freeze,
          errors: Array(errors).dup.freeze,
          as_of: as_of,
          raw_reference: raw_reference
        )
        freeze
      end

      # Fail closed, for the service types the inquiry actually asked.
      #
      # Only coverage benefits count: EB01 "1" (active) and "6" (inactive),
      # and only when `service_type_code` is one of `service_type_codes`.
      # A nil or blank service type is health benefit plan coverage and
      # counts only when "30" was asked. Copays, coinsurance, and the other
      # EB01 variants do not answer. Any AAA error is `:undetermined`.
      #
      # `:active` requires a counted "1" and no counted "6". `:inactive`
      # requires a counted "6" and no counted "1". Both, or neither, is
      # `:undetermined`.
      #
      # An otherwise `:active` answer is `:undetermined` when `service_date`
      # falls outside a contributing plan's coverage window: `coverage_start`
      # after the service date, or `coverage_end` before it. The window is
      # inclusive. A nil bound is unknown — a year-9999 end is stored as nil
      # — and is not checked on that side. The answer is also
      # `:undetermined` when any plan's `eligibility_date` is present and
      # differs from `service_date`. A nil `service_date` skips both checks.
      #
      # An otherwise `:inactive` answer is `:undetermined` when any stated
      # window contains `service_date`. The window needs at least one bound.
      # Bounds are inclusive, and a nil side is open. A window with no
      # bounds does not contradict `:inactive`. The answer is also
      # `:undetermined` when any plan's `eligibility_date` is present and
      # differs from `service_date`. A nil `service_date` skips both checks.
      # `coverage_start` and `coverage_end` do not decide an inactive answer.
      #
      # When `payer_identifier` is present, a contributing plan whose
      # `payer_identifier` is nil or different yields `:undetermined`. A nil
      # or blank inquiry payer skips that check. Contributing plans are those
      # with a counted coverage benefit.
      #
      # @param plans [Array<EligibilityPlan>]
      # @param errors [Array<EligibilityError>] AAA rejects; any one fails closed
      # @param service_type_codes [Array<String>] service types the inquiry asked
      # @param service_date [Date, nil] day the coverage window, stated windows, and eligibility date are checked against
      # @param payer_identifier [String, nil] inquiry payer; must match contributing plans
      # @return [Symbol] `:active`, `:inactive`, or `:undetermined`
      def self.outcome_for(plans:, errors:, service_type_codes:, service_date:, payer_identifier: nil)
        return :undetermined if Array(errors).any?
        return :undetermined if payer_mismatch?(plans, service_type_codes, payer_identifier)

        counted = counted_coverage_benefits(plans, service_type_codes)
        active = coverage_code?(counted, ACTIVE_COVERAGE_CODE)
        inactive = coverage_code?(counted, INACTIVE_COVERAGE_CODE)
        return :undetermined if active && inactive
        return inactive_outcome(plans, service_date) if inactive
        return :undetermined unless active
        return :undetermined if service_date_outside_window?(plans, service_type_codes, service_date)
        return :undetermined if eligibility_dates_differ?(plans, service_date)

        :active
      end

      def self.counted_coverage_benefits(plans, service_type_codes)
        asked = Array(service_type_codes).map(&:to_s)
        benefits = Array(plans).flat_map { |plan| Array(plan.benefits) }
        benefits.select { |benefit| counts_toward_outcome?(benefit, asked) }
      end
      private_class_method :counted_coverage_benefits

      def self.counts_toward_outcome?(benefit, asked)
        return false unless coverage_answer?(benefit)

        service_type_asked?(benefit.service_type_code, asked)
      end
      private_class_method :counts_toward_outcome?

      def self.coverage_answer?(benefit)
        code = benefit.code.to_s
        code == ACTIVE_COVERAGE_CODE || code == INACTIVE_COVERAGE_CODE
      end
      private_class_method :coverage_answer?

      def self.service_type_asked?(service_type_code, asked)
        if blank_service_type?(service_type_code)
          asked.include?(HEALTH_BENEFIT_PLAN_COVERAGE)
        else
          asked.include?(service_type_code.to_s)
        end
      end
      private_class_method :service_type_asked?

      def self.blank_service_type?(service_type_code)
        service_type_code.nil? || service_type_code.to_s.strip.empty?
      end
      private_class_method :blank_service_type?

      def self.coverage_code?(benefits, code)
        benefits.any? { |benefit| benefit.code.to_s == code }
      end
      private_class_method :coverage_code?

      # Dates apply only to plans that supplied a counted active benefit.
      # One such plan outside the window fails the whole answer closed.
      def self.service_date_outside_window?(plans, service_type_codes, service_date)
        return false if service_date.nil?

        active_plans(plans, service_type_codes).any? do |plan|
          plan_excludes_date?(plan, service_date)
        end
      end
      private_class_method :service_date_outside_window?

      def self.active_plans(plans, service_type_codes)
        Array(plans).select { |plan| active_coverage?(plan, service_type_codes) }
      end
      private_class_method :active_plans

      def self.active_coverage?(plan, service_type_codes)
        counted_coverage_benefits([ plan ], service_type_codes).any? do |benefit|
          benefit.code.to_s == ACTIVE_COVERAGE_CODE
        end
      end
      private_class_method :active_coverage?

      def self.plan_excludes_date?(plan, service_date)
        start_on = plan.coverage_start
        end_on = plan.coverage_end
        (start_on && service_date < start_on) || (end_on && service_date > end_on)
      end
      private_class_method :plan_excludes_date?

      def self.inactive_outcome(plans, service_date)
        return :undetermined if inactive_contradicted?(plans, service_date)

        :inactive
      end
      private_class_method :inactive_outcome

      # A stated window that contains the service date, or an eligibility
      # day other than the service date, contradicts an inactive answer.
      # No stated bounds and no eligibility day leave `:inactive` alone.
      def self.inactive_contradicted?(plans, service_date)
        return false if service_date.nil?

        Array(plans).any? { |plan| plan_contradicts_inactive?(plan, service_date) }
      end
      private_class_method :inactive_contradicted?

      def self.plan_contradicts_inactive?(plan, service_date)
        stated_window_contains?(plan, service_date) || eligibility_date_differs?(plan, service_date)
      end
      private_class_method :plan_contradicts_inactive?

      def self.stated_window_contains?(plan, service_date)
        Array(plan.stated_windows).any? { |window| window_contains?(window, service_date) }
      end
      private_class_method :stated_window_contains?

      # Inclusive. A nil side is open. Both nil means the loop stated no
      # bound, and that does not contain the service date.
      def self.window_contains?(window, service_date)
        start_on = window.start_date
        end_on = window.end_date
        return false if start_on.nil? && end_on.nil?

        (start_on.nil? || service_date >= start_on) && (end_on.nil? || service_date <= end_on)
      end
      private_class_method :window_contains?

      # An eligibility day other than the service date means the payer
      # answered for another day. A nil service date skips the check.
      def self.eligibility_dates_differ?(plans, service_date)
        return false if service_date.nil?

        Array(plans).any? { |plan| eligibility_date_differs?(plan, service_date) }
      end
      private_class_method :eligibility_dates_differ?

      def self.eligibility_date_differs?(plan, service_date)
        date = plan.eligibility_date
        !date.nil? && date != service_date
      end
      private_class_method :eligibility_date_differs?

      def self.payer_mismatch?(plans, service_type_codes, payer_identifier)
        return false if payer_identifier.nil? || payer_identifier.to_s.strip.empty?

        coverage_plans(plans, service_type_codes).any? do |plan|
          plan.payer_identifier != payer_identifier
        end
      end
      private_class_method :payer_mismatch?

      def self.coverage_plans(plans, service_type_codes)
        Array(plans).select { |plan| coverage_plan?(plan, service_type_codes) }
      end
      private_class_method :coverage_plans

      def self.coverage_plan?(plan, service_type_codes)
        counted_coverage_benefits([ plan ], service_type_codes).any?
      end
      private_class_method :coverage_plan?
    end
  end
end
