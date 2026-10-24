# frozen_string_literal: true

module Corvid
  # The one rule for a claim's paid, adjusted and denied amounts.
  #
  # RemittanceProcessor and ReferralBillingReconciliation both ask this,
  # so a later remittance adds to the claim instead of replacing what an
  # earlier one paid. Status is the caller's decision: the totals, the
  # lines in payment order, and the latest line are returned with the
  # attributes to write.
  #
  # A line belongs to the claim when its claim_identifier, stripped, is
  # the claim's. payment_date orders those lines. A Date, a Time (its
  # calendar date), or an ISO-8601 date string (Date.iso8601) is dated.
  # Anything else, including nil, is undated. Dated lines come first, by
  # date, with array order breaking a tie. Undated lines follow, still in
  # array order. The latest line is the last one in that order.
  #
  # paid_date is written only from the latest dated line. When no line is
  # dated the attribute is omitted, so an undated line does not clear a
  # date already stored. ReferralBillingReconciliation writes these
  # attributes unchanged.
  #
  # Amounts are integer subunits of the row's currency (ADR 0004).
  # Money.from_amount rounds with that currency, so nothing here hardcodes
  # a factor of 100. An Integer or BigDecimal is taken as given, and a
  # Float is read through to_s so two binary fractions are not summed a
  # cent short. A Money whose currency matches the claim's currency_iso
  # contributes its exact cents; a Money in any other currency raises. A
  # string is stripped; a blank one is not stated. Otherwise it may carry
  # an optional sign, an optional "$", thousands commas, and a decimal
  # point with or without leading digits (".50", "+50"), and is then parsed
  # with BigDecimal. Monetize reads a blank or a word such as a non-amount
  # as zero, so it cannot refuse a value we cannot parse. Anything else
  # raises ArgumentError naming the claim identifier and the field only
  # (ADR 0003: no free text in the message).
  class RemittanceAmounts
    Result = Struct.new(:attributes, :totals, :latest_line, :lines, keyword_init: true)

    # Remittance line fields summed toward settlement, keyed by total name.
    TOTAL_FIELDS = {
      paid: :paid_amount, adjustment: :adjustment_amount,
      patient_responsibility: :patient_responsibility, denied: :denied_amount
    }.freeze
    private_constant :TOTAL_FIELDS

    # Optional sign, optional "$" (and "$" before a sign), thousands commas,
    # digits optional before the decimal point.
    AMOUNT_STRING = /\A(?:[+-]?\$?|\$[+-])(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d+)\z/
    private_constant :AMOUNT_STRING

    def self.call(claim:, remittances:)
      new.call(claim: claim, remittances: remittances)
    end

    # remittance_identifier, or the whole remittance when it has none.
    # RemittanceProcessor uses this to tell which lines belong to the batch.
    def self.remittance_key(remittance)
      remittance[:remittance_identifier].presence || remittance
    end

    # Integer subunits for one reported amount (ADR 0004). nil and a blank
    # string count as zero toward a total; whether any line stated the
    # field is separate. A Money contributes its exact cents when its
    # currency matches, and never a float conversion.
    def self.cents(value, currency_iso, claim_identifier: nil, field: nil)
      return money_cents(value, currency_iso, claim_identifier, field) if value.is_a?(Money)

      decimal = decimal_for(value, claim_identifier, field)
      return 0 if decimal.nil?

      Money.from_amount(decimal, currency_iso).cents
    rescue ArgumentError
      raise ArgumentError, invalid_amount(field, claim_identifier)
    end

    # nil when no line for the claim survives deduplication, so the caller
    # records nothing rather than inventing a zero payment.
    def call(claim:, remittances:)
      lines = matching_lines(claim, remittances)
      return if lines.empty?

      totals = totals_in_cents(lines, claim)
      Result.new(
        attributes: attributes_for(lines, totals),
        totals: totals,
        latest_line: lines.last,
        lines: lines
      )
    end

    class << self
      private

      def money_cents(value, currency_iso, claim_identifier, field)
        unless value.currency.iso_code == currency_iso.to_s
          raise ArgumentError, invalid_amount(field, claim_identifier)
        end

        value.cents
      end

      def decimal_for(value, claim_identifier, field)
        case value
        when nil then nil
        when String then decimal_from_string(value, claim_identifier, field)
        when Float then BigDecimal(value.to_s)
        when Integer, BigDecimal then BigDecimal(value)
        else raise ArgumentError, invalid_amount(field, claim_identifier)
        end
      end

      def decimal_from_string(value, claim_identifier, field)
        stripped = value.strip
        return nil if stripped.empty?
        unless stripped.match?(AMOUNT_STRING)
          raise ArgumentError, invalid_amount(field, claim_identifier)
        end

        BigDecimal(stripped.delete(",$"))
      end

      def invalid_amount(field, claim_identifier)
        "invalid #{field} for claim #{claim_identifier}"
      end
    end

    private

    # Every line for the claim across all remittances, oldest payment first.
    # Array order breaks a tie on payment_date, so the last line is the latest.
    # A remittance returned twice counts once: by remittance_identifier, or
    # by its whole content when it has none, since counting a duplicate
    # twice could settle a claim that is only partly paid. Each line carries
    # :remittance_key, that same dedupe key, so a caller can tell which
    # lines belong to one batch.
    # Reversals carry negative amounts, so a reversed payment and its
    # corrected replacement sum to the corrected figures.
    def matching_lines(claim, remittances)
      ordered(lines_for(claim, unique_remittances(remittances)))
    end

    def unique_remittances(remittances)
      seen = Set.new
      remittances.select { |remittance| seen.add?(remittance_key(remittance)) }
    end

    def remittance_key(remittance)
      self.class.remittance_key(remittance)
    end

    def lines_for(claim, remittances)
      remittances.flat_map do |remittance|
        key = remittance_key(remittance)
        Array(remittance[:line_items]).filter_map do |line|
          next unless for_claim?(line, claim)

          line.merge(payment_date: remittance[:payment_date], remittance_key: key)
        end
      end
    end

    # Surrounding whitespace is not part of the identifier. A blank name
    # matches no claim, including one whose identifier is NULL.
    def for_claim?(line, claim)
      identifier = line[:claim_identifier].to_s.strip
      identifier.present? && identifier == claim.claim_identifier.to_s.strip
    end

    def ordered(lines)
      lines.sort_by.with_index { |line, index| sort_key(line, index) }
    end

    # Dated lines sort by the date, then by the position they arrived in.
    # Undated lines sort after every dated line, still in arrival order.
    def sort_key(line, index)
      date = payment_on(line[:payment_date])
      date ? [ 0, date, index ] : [ 1, index ]
    end

    # Date.iso8601 is the only string form that counts. A US-style date
    # string is undated and sorts after the dated lines. A Time contributes
    # its calendar date, so the time of day cannot reorder the line or shift
    # paid_date when the column stores a date.
    def payment_on(value)
      case value
      when Time then value.to_date
      when Date then value.to_date
      when String then Date.iso8601(value)
      end
    rescue Date::Error
      nil
    end

    def totals_in_cents(lines, claim)
      TOTAL_FIELDS.transform_values { |field| sum_field(lines, claim, field) }
    end

    def sum_field(lines, claim, field)
      lines.sum do |line|
        self.class.cents(
          line[field], claim.currency_iso,
          claim_identifier: claim.claim_identifier, field: field
        )
      end
    end

    def stated?(lines, field)
      lines.any? { |line| stated_value?(line[field]) }
    end

    # A blank string states nothing. Nil states nothing. Zero states zero.
    def stated_value?(value)
      case value
      when nil then false
      when String then !value.strip.empty?
      else true
      end
    end

    # A field no line states is omitted, so the stored value is left alone.
    # A denied amount is an adjustment in 835 terms (a CAS segment), so it
    # is stored with the adjustments and #balance_due does not report the
    # denied portion as still owed.
    def attributes_for(lines, totals)
      attrs = {}
      date = paid_on(lines)
      attrs[:paid_date] = date if date
      attrs[:paid_amount_cents] = totals[:paid] if stated?(lines, :paid_amount)
      if stated?(lines, :patient_responsibility)
        attrs[:patient_responsibility_cents] = totals[:patient_responsibility]
      end
      if stated?(lines, :adjustment_amount) || stated?(lines, :denied_amount)
        attrs[:adjustment_amount_cents] = totals[:adjustment] + totals[:denied]
      end
      attrs
    end

    def paid_on(lines)
      lines.reverse_each do |line|
        date = payment_on(line[:payment_date])
        return date if date
      end
      nil
    end
  end
end
