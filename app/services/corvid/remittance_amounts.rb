# frozen_string_literal: true

module Corvid
  # The one rule for a claim's paid, adjusted and denied amounts.
  #
  # RemittanceProcessor and ReferralBillingReconciliation both ask this,
  # so a later remittance adds to the claim instead of replacing what an
  # earlier one paid. Status is the caller's decision: the totals and the
  # latest line are returned with the attributes to write.
  class RemittanceAmounts
    Result = Struct.new(:attributes, :totals, :latest_line, keyword_init: true)

    # Remittance line fields summed toward settlement, keyed by total name.
    TOTAL_FIELDS = {
      paid: :paid_amount, adjustment: :adjustment_amount,
      patient_responsibility: :patient_responsibility, denied: :denied_amount
    }.freeze
    private_constant :TOTAL_FIELDS

    def self.call(claim:, remittances:)
      new.call(claim: claim, remittances: remittances)
    end

    # nil when no line for the claim survives deduplication, so the caller
    # records nothing rather than inventing a zero payment.
    def call(claim:, remittances:)
      lines = matching_lines(claim, remittances)
      return if lines.empty?

      totals = totals_in_cents(lines, claim.currency_iso)
      Result.new(
        attributes: attributes_for(lines, totals),
        totals: totals,
        latest_line: lines.last
      )
    end

    # Integer subunits for one reported amount (ADR 0004). nil counts as
    # zero toward a total; whether any line stated the field is separate.
    def self.cents(value, currency_iso)
      return 0 if value.nil?

      Money.from_amount(BigDecimal(value.to_s), currency_iso).cents
    end

    private

    # Every line for the claim across all remittances, oldest payment first.
    # Array order breaks a tie on payment_date, so the last line is the latest.
    # A remittance returned twice counts once: by remittance_identifier, or
    # by its whole content when it has none, since counting a duplicate
    # twice could settle a claim that is only partly paid.
    # Reversals carry negative amounts, so a reversed payment and its
    # corrected replacement sum to the corrected figures.
    def matching_lines(claim, remittances)
      seen = Set.new
      lines = remittances.each_with_object([]) do |remittance, out|
        next unless seen.add?(remittance[:remittance_identifier].presence || remittance)

        Array(remittance[:line_items]).each do |line|
          next unless line[:claim_identifier] == claim.claim_identifier

          out << line.merge(payment_date: remittance[:payment_date])
        end
      end
      lines.sort_by.with_index { |line, i| [ line[:payment_date].to_s, i ] }
    end

    # Summed in integer subunits (ADR 0004): binary floats read
    # $100.05 + $0.10 as a cent short of $100.15.
    def totals_in_cents(lines, currency_iso)
      TOTAL_FIELDS.transform_values do |field|
        lines.sum { |line| self.class.cents(line[field], currency_iso) }
      end
    end

    def stated?(lines, field)
      lines.any? { |line| !line[field].nil? }
    end

    # paid_date is the latest line. A field no line states is omitted, so
    # the stored value is left alone. A denied amount is an adjustment in
    # 835 terms (a CAS segment), so it is stored with the adjustments and
    # #balance_due does not report the denied portion as still owed.
    def attributes_for(lines, totals)
      attrs = { paid_date: lines.last[:payment_date] }
      attrs[:paid_amount_cents] = totals[:paid] if stated?(lines, :paid_amount)
      if stated?(lines, :patient_responsibility)
        attrs[:patient_responsibility_cents] = totals[:patient_responsibility]
      end
      if stated?(lines, :adjustment_amount) || stated?(lines, :denied_amount)
        attrs[:adjustment_amount_cents] = totals[:adjustment] + totals[:denied]
      end
      attrs
    end
  end
end
