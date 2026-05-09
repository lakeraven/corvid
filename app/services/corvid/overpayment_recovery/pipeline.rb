# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Aggregates an in-memory list of demands by status into the totals
    # a recovery dashboard wants to display:
    #   - in_collection: sum of demands still being chased (sent / follow_up)
    #   - collected: sum of demands paid in full
    #   - pending_payout: sum collected but not yet split to the customer
    #
    # Each demand is a Hash with at minimum :amount and :status. If a
    # demand has been partially paid, callers can pass :collected_amount
    # so the pipeline reports payable-now rather than nominal-collected.
    module Pipeline
      Result = Struct.new(
        :in_collection, :collected, :pending_payout,
        :counts_by_status,
        keyword_init: true
      )

      IN_COLLECTION_STATUSES = %w[sent follow_up escalated].freeze
      COLLECTED_STATUSES = %w[collected paid_in_full].freeze

      def self.summarize(demands)
        in_coll = sum_amount(demands.select { |d| IN_COLLECTION_STATUSES.include?(d[:status].to_s) })
        coll = sum_amount(demands.select { |d| COLLECTED_STATUSES.include?(d[:status].to_s) })
        pending = sum_collected_amount(demands.select { |d| COLLECTED_STATUSES.include?(d[:status].to_s) })

        Result.new(
          in_collection: in_coll,
          collected: coll,
          pending_payout: pending,
          counts_by_status: demands.group_by { |d| d[:status].to_s }.transform_values(&:size)
        )
      end

      def self.sum_amount(rows)
        rows.sum(BigDecimal("0")) { |d| BigDecimal(d[:amount].to_s) }
      end

      def self.sum_collected_amount(rows)
        rows.sum(BigDecimal("0")) { |d| BigDecimal((d[:collected_amount] || d[:amount]).to_s) }
      end
    end
  end
end
