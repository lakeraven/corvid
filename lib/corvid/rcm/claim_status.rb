# frozen_string_literal: true

require "bigdecimal"
require "date"
require "yaml"

module Corvid
  module Rcm
    # One answer to a 276 claim-status request (the 277). This is not an
    # Acknowledgment and not a RemittanceClaim. A front-end rejection and an
    # adjudicated denial are different categories here, and only the mapping
    # table may say which codes mean which. A code that is not in the table is
    # :undetermined — never paid, never denied.
    #
    # `category_code` and `status_code` are the raw STC composite values
    # (STC01-1 and STC01-2). They are stored as the payer sent them. The
    # category must be what `category_for` says that code means. `:not_found`
    # may omit the code: a claim that is not on file has no STC01-1.
    #
    # Money and dates are exact. `paid_amount`, when present, is a finite,
    # non-negative BigDecimal with at most two decimal places, and only
    # `:finalized_paid` may carry one. `paid_date` is a Date, and only
    # `:finalized_paid` may carry one. `as_of` is nil or a Time. Each refusal
    # is an ArgumentError with a fixed message that echoes no claim data.
    class ClaimStatus < Data.define(
      :claim_identifier,
      :payer_control_number,
      :category,
      :category_code,
      :status_code,
      :paid_amount,
      :paid_date,
      :as_of,
      :raw_reference
    )
      CATEGORIES = %i[
        acknowledged
        pending
        finalized_paid
        finalized_denied
        rejected
        not_found
        undetermined
      ].freeze

      CATEGORY_TABLE_PATH = File.expand_path("data/claim_status_categories.yml", __dir__).freeze

      INVALID_CLAIM_IDENTIFIER = "claim_identifier must be a non-blank String"
      UNKNOWN_CATEGORY = "unknown claim status category"
      INVALID_PAID_AMOUNT = "paid_amount must be nil or a BigDecimal"
      INVALID_PAID_AMOUNT_PRECISION =
        "paid_amount must be a finite non-negative BigDecimal with at most two decimal places"
      INVALID_PAID_DATE = "paid_date must be nil or a Date"
      INVALID_AS_OF = "as_of must be nil or a Time"
      CATEGORY_DISAGREES = "category does not agree with the category code"
      PAID_AMOUNT_NOT_ALLOWED = "paid_amount is only allowed for category finalized_paid"
      PAID_DATE_NOT_ALLOWED = "paid_date is only allowed for category finalized_paid"

      OPTIONAL_MEMBERS = {
        payer_control_number: nil,
        category_code: nil,
        status_code: nil,
        paid_amount: nil,
        paid_date: nil,
        as_of: nil,
        raw_reference: nil
      }.freeze

      class << self
        # Exact match on the STC01-1 code. No case folding and no stripping.
        # Nil and any code absent from the table are :undetermined.
        def category_for(code)
          name = category_table[code]
          return :undetermined if name.nil?

          CATEGORIES.find { |category| category.to_s == name }
        end

        private

        def category_table
          @category_table ||= load_category_table
        end

        def load_category_table
          table = YAML.safe_load_file(CATEGORY_TABLE_PATH, freeze: true)
          validate_category_table!(table)
          table
        end

        def validate_category_table!(table)
          raise ArgumentError, "claim status category table must be a mapping" unless table.is_a?(Hash)

          names = CATEGORIES.map(&:to_s)
          table.each { |code, category| validate_category_entry!(code, category, names) }
        end

        def validate_category_entry!(code, category, names)
          unless code.is_a?(String) && !code.empty?
            raise ArgumentError, "claim status category code must be a non-blank String"
          end
          return if category.is_a?(String) && names.include?(category)

          raise ArgumentError, UNKNOWN_CATEGORY
        end
      end

      def initialize(**members)
        members = OPTIONAL_MEMBERS.merge(members)
        validate!(members)
        super(**freeze_strings(members))
        freeze
      end

      def paid?
        category == :finalized_paid
      end

      def denied?
        category == :finalized_denied
      end

      # Front-end refusal. Never an adjudicated denial.
      def rejected?
        category == :rejected
      end

      def pending?
        category == :pending
      end

      # The payer finished with a pay or deny decision. A rejection is not
      # final, and neither is an undetermined finalized code.
      def final?
        paid? || denied?
      end

      private

      def validate!(members)
        validate_category!(members[:category])
        validate_claim_identifier!(members[:claim_identifier])
        validate_paid_amount!(members[:paid_amount])
        validate_paid_date!(members[:paid_date])
        validate_as_of!(members[:as_of])
        validate_agreement!(members[:category], members[:category_code])
        validate_paid_amount_allowed!(members[:category], members[:paid_amount])
        validate_paid_date_allowed!(members[:category], members[:paid_date])
      end

      def validate_category!(category)
        return if CATEGORIES.include?(category)

        raise ArgumentError, UNKNOWN_CATEGORY
      end

      def validate_claim_identifier!(claim_identifier)
        return if claim_identifier.is_a?(String) && !claim_identifier.strip.empty?

        raise ArgumentError, INVALID_CLAIM_IDENTIFIER
      end

      def validate_paid_amount!(paid_amount)
        return if paid_amount.nil?
        raise ArgumentError, INVALID_PAID_AMOUNT unless paid_amount.instance_of?(BigDecimal)
        return if acceptable_paid_amount?(paid_amount)

        raise ArgumentError, INVALID_PAID_AMOUNT_PRECISION
      end

      def acceptable_paid_amount?(paid_amount)
        paid_amount.finite? && paid_amount >= 0 && paid_amount.scale <= 2
      end

      def validate_paid_date!(paid_date)
        return if paid_date.nil? || paid_date.instance_of?(Date)

        raise ArgumentError, INVALID_PAID_DATE
      end

      def validate_as_of!(as_of)
        return if as_of.nil? || as_of.instance_of?(Time)

        raise ArgumentError, INVALID_AS_OF
      end

      # :not_found may carry a nil category code: the claim was not on file,
      # so there is no STC01-1 to agree with. Every other pair must match
      # category_for.
      def validate_agreement!(category, category_code)
        return if category == :not_found && category_code.nil?
        return if category == self.class.category_for(category_code)

        raise ArgumentError, CATEGORY_DISAGREES
      end

      def validate_paid_amount_allowed!(category, paid_amount)
        return if paid_amount.nil?
        return if category == :finalized_paid

        raise ArgumentError, PAID_AMOUNT_NOT_ALLOWED
      end

      def validate_paid_date_allowed!(category, paid_date)
        return if paid_date.nil?
        return if category == :finalized_paid

        raise ArgumentError, PAID_DATE_NOT_ALLOWED
      end

      def freeze_strings(members)
        members.transform_values { |value| value.is_a?(String) ? -value : value }
      end
    end
  end
end
