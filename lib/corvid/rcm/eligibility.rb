# frozen_string_literal: true

require "bigdecimal"
require "date"

module Corvid
  module Rcm
    # Real-time eligibility shapes for the clearinghouse port (X12 271).
    #
    # These are in-memory boundary values, like Claim and Remittance: no
    # ActiveRecord, no persistence. Unknown is never a no. Only an explicit
    # inactive answer is `:inactive`; an error, a timeout, or any unmapped
    # answer is `:undetermined` (42 CFR 136.61).
    #
    # EB01 codes that are an explicit coverage answer. "1" is active coverage.
    # "6" is inactive. The other active and inactive variants (2–5, 7, 8) are
    # not a clear yes or no, and a benefit such as a copay (B) or coinsurance
    # (A) does not answer the coverage question by itself.
    ACTIVE_COVERAGE_CODE = "1"
    INACTIVE_COVERAGE_CODE = "6"

    ELIGIBILITY_OUTCOMES = %i[active inactive undetermined].freeze

    # X12 271 default service type: 30 = Health Benefit Plan Coverage.
    DEFAULT_SERVICE_TYPE_CODES = [ "30" ].freeze

    # One eligibility question. Identifiers are opaque tokens (ADR 0003).
    # `member_identifier` may be nil when the caller does not have one; that
    # is an undetermined check, not an inactive one.
    EligibilityInquiry = Data.define(
      :patient_identifier,
      :payer_identifier,
      :member_identifier,
      :service_date,
      :service_type_codes,
      :provider_npi
    ) do
      def initialize(patient_identifier:, payer_identifier:, service_date:, provider_npi:,
                     member_identifier: nil, service_type_codes: DEFAULT_SERVICE_TYPE_CODES)
        super(
          patient_identifier: patient_identifier,
          payer_identifier: payer_identifier,
          member_identifier: member_identifier,
          service_date: service_date,
          service_type_codes: Array(service_type_codes).dup.freeze,
          provider_npi: provider_npi
        )
        freeze
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

    # Coverage for one plan on the 271. A year-9999 end date is open-ended and
    # is stored as nil — payers use 9999-12-31 (and nearby days) as a
    # placeholder, not as a real termination.
    EligibilityPlan = Data.define(
      :payer_identifier,
      :plan_name,
      :group_number,
      :coverage_start,
      :coverage_end,
      :benefits
    ) do
      def initialize(payer_identifier:, plan_name: nil, group_number: nil, coverage_start: nil,
                     coverage_end: nil, benefits: [])
        super(
          payer_identifier: payer_identifier,
          plan_name: plan_name,
          group_number: group_number,
          coverage_start: coverage_start,
          coverage_end: coverage_end,
          benefits: Array(benefits).dup.freeze
        )
        freeze
      end

      # CCYYMMDD or CCYY-MM-DD. Blank, a year-9999 placeholder, and an
      # impossible calendar day are nil. Nothing here raises: a bad date on a
      # 271 is an unknown bound, not a crashed check.
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

      # Fail closed. `:active` requires an EB01 of "1" and no AAA reject.
      # `:inactive` requires an EB01 of "6", no active EB, and no AAA reject.
      # Both at once, neither, or any reject is `:undetermined`.
      def self.outcome_for(plans:, errors:)
        return :undetermined if Array(errors).any?

        codes = benefit_codes(plans)
        active = codes.include?(ACTIVE_COVERAGE_CODE)
        inactive = codes.include?(INACTIVE_COVERAGE_CODE)
        return :active if active && !inactive
        return :inactive if inactive && !active

        :undetermined
      end

      def self.benefit_codes(plans)
        Array(plans).flat_map { |plan| Array(plan.benefits).map { |benefit| benefit.code.to_s } }
      end
      private_class_method :benefit_codes
    end
  end
end
