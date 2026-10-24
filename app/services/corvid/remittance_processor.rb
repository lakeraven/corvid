# frozen_string_literal: true

module Corvid
  # Applies 835 remittances (as returned by Corvid.adapter.fetch_remittances)
  # to the claims they settle.
  #
  # Amounts are written once per claim, from RemittanceAmounts, over every
  # line for that claim in the batch. The last line does not replace an
  # earlier payment. Duplicate remittances and reversals are netted there,
  # in integer cents, the same rule ReferralBillingReconciliation uses.
  #
  # Status still comes from the latest line (latest payment_date, batch
  # order breaking a tie). A line the adapter marks "denied" is the payer's
  # adjudicated decision: its CARC/RARC codes (adjustment_codes) are
  # recorded on the claim. Otherwise a positive paid amount on that line
  # marks the claim paid. Anything else only writes the amounts.
  #
  # Free-text denial reasons on the line item are not stored: per ADR 0003
  # text is kept only as a vault token, and the codes already say why.
  #
  # Runs inside the caller's tenant context; line items whose claim is not
  # in that tenant are skipped, never matched across tenants. Each matched
  # claim counts once toward paid, denied or updated. A line that names no
  # claim in this tenant counts as unmatched.
  class RemittanceProcessor
    Result = Struct.new(:paid, :denied, :updated, :unmatched, keyword_init: true)

    def self.call(remittances)
      new.call(remittances)
    end

    def call(remittances)
      result = Result.new(paid: 0, denied: 0, updated: 0, unmatched: 0)
      batch = Array(remittances)
      claims_in(batch, result).each { |claim| tally(result, apply_claim(claim, batch)) }
      result
    end

    private

    # One entry per claim the batch names. Each unmatched line is counted
    # on its own; a claim's amounts are written once.
    def claims_in(remittances, result)
      remittances.each_with_object({}) do |remittance, claims|
        Array(remittance[:line_items]).each do |item|
          claim = claim_for(item)
          if claim
            claims[claim.id] ||= claim
          else
            result.unmatched += 1
          end
        end
      end.values
    end

    # A line with no claim identifier names no claim. Looking it up
    # anyway would match an unsubmitted claim whose identifier is NULL.
    # The lookup is the tenant-scoped finder, so another tenant's claim
    # is not a match.
    def claim_for(item)
      claim_identifier = item[:claim_identifier].to_s.strip.presence
      claim_identifier && ClaimSubmission.find_by(claim_identifier: claim_identifier)
    end

    def apply_claim(claim, remittances)
      amounts = RemittanceAmounts.call(claim: claim, remittances: remittances)
      apply_status(claim, amounts) if amounts
    end

    # The latest line decides. A denial records that line's codes; a
    # positive payment, compared in subunits rather than as a float,
    # marks the claim paid.
    def apply_status(claim, amounts)
      line = amounts.latest_line
      if line[:status].to_s == "denied"
        deny_claim(claim, amounts, line)
      elsif positive_paid?(line[:paid_amount], claim.currency_iso)
        claim.update!(amounts.attributes.merge(status: "paid"))
        :paid
      else
        claim.update!(amounts.attributes)
        :updated
      end
    end

    def deny_claim(claim, amounts, line)
      claim.assign_attributes(amounts.attributes)
      claim.mark_denied!(reason_codes: adjustment_codes(line))
      :denied
    end

    def positive_paid?(amount, currency_iso)
      RemittanceAmounts.cents(amount, currency_iso).positive?
    end

    def tally(result, outcome)
      case outcome
      when :denied then result.denied += 1
      when :paid then result.paid += 1
      when :updated then result.updated += 1
      end
    end

    # Adapters report codes either as strings ("CO-97", "CO-97:$50.00") or as
    # hashes ({ group_code: "CO", reason_code: "97" }). Normalize to "CO-97".
    def adjustment_codes(item)
      Array(item[:adjustment_codes]).filter_map do |code|
        if code.is_a?(Hash)
          group = code[:group_code] || code["group_code"]
          reason = code[:reason_code] || code["reason_code"] || code[:code] || code["code"]
          [ group, reason ].compact.join("-").presence
        else
          code.to_s.split(":").first.to_s.strip.presence
        end
      end
    end
  end
end
