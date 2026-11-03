# frozen_string_literal: true

require "bigdecimal"
require "date"

module Corvid
  module Rcm
    # One credit that reached the bank, to be reassociated with an 835.
    #
    # `trace_number` is the EFT reassociation trace the payer put on the
    # payment and copied into TRN02. It is an identifier, not a number, so
    # leading zeros and letter case belong to it. `deposit_identifier` is the
    # bank's own reference (ADR 0001 — not a Rails key). `payer_name` is
    # optional text off the bank feed; it is never a match key.
    #
    # Amounts stay BigDecimal so two equal payments compare exactly. An
    # Integer is stored as BigDecimal. Float and String are refused rather
    # than coerced: coercion would hide a rounding or a parse (ADR 0004).
    # A non-finite BigDecimal is refused too: Infinity and NaN are not
    # money (ADR 0004). Messages stay generic so an amount, a trace, or a
    # payer name cannot leak into an exception.
    Deposit = Data.define(
      :deposit_identifier,
      :trace_number,
      :amount,
      :deposited_on,
      :payer_name
    ) do
      def initialize(deposit_identifier:, trace_number:, amount:, deposited_on:, payer_name: nil)
        super(
          deposit_identifier: validated_identifier(deposit_identifier),
          trace_number: validated_trace(trace_number),
          amount: validated_amount(amount),
          deposited_on: validated_date(deposited_on),
          payer_name: payer_name
        )
      end

      private

      def validated_identifier(value)
        return value if value.is_a?(String) && !value.strip.empty?

        raise ArgumentError, "deposit identifier must be a non-blank string"
      end

      def validated_trace(value)
        return value if value.nil? || value.is_a?(String)

        raise ArgumentError, "deposit trace number must be a string or nil"
      end

      def validated_amount(value)
        return value if value.is_a?(BigDecimal) && value.finite?
        return BigDecimal(value) if value.is_a?(Integer)

        raise ArgumentError, "deposit amount must be a BigDecimal or Integer"
      end

      def validated_date(value)
        return value if value.instance_of?(Date)

        raise ArgumentError, "deposited_on must be a Date"
      end
    end
  end
end
