# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Splits a demand into N equal monthly installments. Rounding goes
    # to two decimal places per installment; any remainder from rounding
    # is absorbed into the final installment so the sum equals the
    # original demand exactly.
    module InstallmentPlan
      Plan = Struct.new(:total, :installments, :payment_count, :monthly_amount,
                        keyword_init: true)

      def self.create(demand_total:, payment_count:, first_due:)
        unless payment_count.is_a?(Integer) && payment_count.positive?
          raise ArgumentError,
                "payment_count must be a positive integer (got #{payment_count.inspect})"
        end

        total = BigDecimal(demand_total.to_s).round(2)
        per_payment = (total / payment_count).round(2)

        amounts = Array.new(payment_count, per_payment)
        sum = amounts.sum
        amounts[-1] = (per_payment + (total - sum)).round(2)

        installments = amounts.each_with_index.map do |amt, i|
          { due: first_due >> i, amount: amt }
        end

        Plan.new(
          total: total,
          installments: installments,
          payment_count: payment_count,
          monthly_amount: per_payment
        )
      end
    end
  end
end
