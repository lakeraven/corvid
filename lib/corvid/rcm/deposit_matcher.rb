# frozen_string_literal: true

require "bigdecimal"

require_relative "deposit"
require_relative "remittance"

module Corvid
  module Rcm
    # One remittance and the deposit that paid it. The original objects, so
    # posting does not need a second lookup.
    DepositMatch = Data.define(:remittance, :deposit)

    # Same trace, different money. `difference` is the deposit minus the
    # remittance payment: positive means the bank received more than the 835
    # claims. BigDecimal only, so the sign is exact.
    DepositAmountMismatch = Data.define(:remittance, :deposit, :difference) do
      def initialize(remittance:, deposit:, difference:)
        raise ArgumentError, "amount difference must be a BigDecimal" unless difference.is_a?(BigDecimal)

        super
      end
    end

    # Every input that is actually a payment lands in exactly one list. The
    # lists are frozen so a caller cannot quietly move an item from "a human
    # must look" into "matched".
    DepositMatchResult = Data.define(
      :matched,
      :unmatched_remittances,
      :unmatched_deposits,
      :amount_mismatches
    ) do
      def initialize(matched:, unmatched_remittances:, unmatched_deposits:, amount_mismatches:)
        super(
          matched: matched.freeze,
          unmatched_remittances: unmatched_remittances.freeze,
          unmatched_deposits: unmatched_deposits.freeze,
          amount_mismatches: amount_mismatches.freeze
        )
      end
    end

    # Reassociates 835 remittances with bank deposits on the TRN trace.
    #
    # A match is one remittance and one deposit with the same trace and the
    # same amount. Surrounding whitespace is stripped; leading zeros and
    # letter case stay, because TRN02 is an identifier, not an integer.
    #
    # Anything that is not that one clear pair waits for a human: a trace
    # that appears more than once on either side (every item with that trace
    # is unmatched), a trace that is blank after stripping, the same trace
    # with a different amount, or a payment with no counterpart. A zero
    # deposit is still reported — only remittances are dropped.
    #
    # Payment method NON, or a zero payment amount, is not money in. That
    # remittance is omitted from every list and does not occupy its trace, so
    # it cannot take a deposit a real payment still needs.
    class DepositMatcher
      # X12 BPR04. "NON" means the 835 has no payment attached.
      NON_PAYMENT_METHOD = "NON"

      def self.match(remittances:, deposits:)
        new(remittances, deposits).result
      end

      def initialize(remittances, deposits)
        @remittances = typed_array(remittances, Remittance, "remittances")
        @deposits = typed_array(deposits, Deposit, "deposits")
      end

      def result
        candidates = payable(@remittances)
        remittance_keys = candidates.map { |remittance| trace_key(remittance.remittance_identifier) }
        deposit_keys = @deposits.map { |deposit| trace_key(deposit.trace_number) }
        blocked = duplicate_keys(remittance_keys).merge(duplicate_keys(deposit_keys))
        matched, mismatches, unmatched = pair(candidates, remittance_keys, blocked)
        build_result(matched, mismatches, unmatched, deposit_keys, remittance_keys, blocked)
      end

      private

      def typed_array(values, type, noun)
        raise ArgumentError, "#{noun} must be an array" unless values.is_a?(Array)
        raise ArgumentError, "#{noun} must contain only #{noun}" unless values.all? { |item| item.is_a?(type) }

        values
      end

      def build_result(matched, mismatches, unmatched, deposit_keys, remittance_keys, blocked)
        DepositMatchResult.new(
          matched: matched,
          unmatched_remittances: unmatched,
          unmatched_deposits: leftover_deposits(deposit_keys, remittance_keys, blocked),
          amount_mismatches: mismatches
        )
      end

      # NON and a zero BPR amount are not payments. Checked before pairing so
      # they cannot count as a duplicate or hold a trace.
      def payable(remittances)
        remittances.reject { |remittance| excluded?(remittance) }
      end

      def excluded?(remittance)
        exact_payment(remittance).zero? || non_payment_method?(remittance.payment_method)
      end

      def non_payment_method?(payment_method)
        payment_method.is_a?(String) && payment_method.strip.upcase(:ascii) == NON_PAYMENT_METHOD
      end

      # Float and String are refused, not coerced. A non-finite BigDecimal
      # is refused too: Infinity and NaN are not money (ADR 0004). An
      # Integer is accepted and widened to BigDecimal so the later
      # subtraction stays exact.
      def exact_payment(remittance)
        amount = remittance.payment_amount
        return amount if amount.is_a?(BigDecimal) && amount.finite?
        return BigDecimal(amount) if amount.is_a?(Integer)

        raise ArgumentError, "remittance payment amount must be a BigDecimal or Integer"
      end

      def duplicate_keys(keys)
        seen = {}
        duplicates = {}
        keys.each do |key|
          next if key.nil?

          duplicates[key] = true if seen[key]
          seen[key] = true
        end
        duplicates
      end

      def pair(candidates, remittance_keys, blocked)
        deposits_by_key = index_deposits(blocked)
        matched = []
        mismatches = []
        unmatched = []
        candidates.each_with_index do |remittance, position|
          deposit = deposit_for(remittance_keys[position], deposits_by_key, blocked)
          record(remittance, deposit, matched, mismatches, unmatched)
        end
        [ matched, mismatches, unmatched ]
      end

      def index_deposits(blocked)
        index = {}
        @deposits.each_with_index do |deposit, position|
          key = trace_key(deposit.trace_number)
          index[key] = deposit if key && !blocked[key]
        end
        index
      end

      def deposit_for(key, deposits_by_key, blocked)
        return nil if key.nil? || blocked[key]

        deposits_by_key[key]
      end

      def record(remittance, deposit, matched, mismatches, unmatched)
        if deposit.nil?
          unmatched << remittance
        elsif same_amount?(deposit, remittance)
          matched << DepositMatch.new(remittance: remittance, deposit: deposit)
        else
          mismatches << amount_mismatch(remittance, deposit)
        end
      end

      def same_amount?(deposit, remittance)
        deposit.amount == exact_payment(remittance)
      end

      def amount_mismatch(remittance, deposit)
        paid = exact_payment(remittance)
        DepositAmountMismatch.new(
          remittance: remittance,
          deposit: deposit,
          difference: deposit.amount - paid
        )
      end

      def leftover_deposits(deposit_keys, remittance_keys, blocked)
        claimed = claimed_keys(remittance_keys, blocked)
        @deposits.select.with_index do |_deposit, position|
          !paired_deposit?(deposit_keys[position], claimed)
        end
      end

      # A key is claimed only when exactly one payable remittance carries it.
      # The deposit on that key was either matched or filed as a mismatch.
      def claimed_keys(remittance_keys, blocked)
        claimed = {}
        remittance_keys.each do |key|
          claimed[key] = true if key && !blocked[key]
        end
        claimed
      end

      def paired_deposit?(key, claimed)
        key && claimed[key]
      end

      # Blank after stripping is not a trace, so two blanks do not match each
      # other and do not count as duplicates. Leading zeros are kept.
      def trace_key(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        return nil if stripped.empty?

        stripped
      end
    end
  end
end
