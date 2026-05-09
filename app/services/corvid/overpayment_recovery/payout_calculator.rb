# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Splits collected recovery dollars between the customer and
    # corvid per the agreed split. The "70/30" naming convention reads
    # as corvid-share / customer-share — the platform takes the larger
    # cut because it does the audit, demand, follow-up, and collection
    # work. Two named splits today:
    #   :standard          — corvid 70%, customer 30%
    #   :corvid_subscriber — corvid 50%, customer 50%
    # Custom splits are accepted as a fraction representing the
    # customer's share (e.g., 0.30 = customer 30%).
    module PayoutCalculator
      Result = Struct.new(:collected, :customer_share, :corvid_share, :remaining_in_collection,
                          keyword_init: true)

      STANDARD_CUSTOMER_SHARE = BigDecimal("0.30")
      CORVID_SUBSCRIBER_CUSTOMER_SHARE = BigDecimal("0.50")

      # `demanded` is the total amount on the demand letter; `collected`
      # is what the provider has paid to date (may be less than demanded
      # for partial payments). The unpaid `remaining_in_collection` keeps
      # accruing interest / follow-ups.
      def self.split(demanded:, collected:, customer_share:)
        demanded = BigDecimal(demanded.to_s)
        collected = BigDecimal(collected.to_s)
        share = resolve_share(customer_share)

        customer = (collected * share).round(2)
        corvid = (collected - customer).round(2)
        remaining = (demanded - collected).round(2)
        remaining = BigDecimal("0") if remaining.negative?

        Result.new(
          collected: collected,
          customer_share: customer,
          corvid_share: corvid,
          remaining_in_collection: remaining
        )
      end

      def self.resolve_share(customer_share)
        case customer_share
        when :standard            then STANDARD_CUSTOMER_SHARE
        when :corvid_subscriber   then CORVID_SUBSCRIBER_CUSTOMER_SHARE
        when Numeric              then BigDecimal(customer_share.to_s)
        else
          raise ArgumentError, "customer_share must be :standard, :corvid_subscriber, or numeric (0..1)"
        end
      end
    end
  end
end
