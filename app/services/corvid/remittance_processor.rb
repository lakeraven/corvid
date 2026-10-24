# frozen_string_literal: true

module Corvid
  # Applies 835 remittances to the claims they settle.
  #
  # The adapter is injected (ADR 0005) and read once per call. For each
  # claim the batch names, amounts are summed over that history together
  # with the batch. RemittanceAmounts deduplicates, so a remittance that
  # appears in both is counted once. A nil read is unknown, not an empty
  # history: nothing is written for the batch's claims, they are counted
  # as unknown, and the batch is never applied on its own. A batch of only
  # the new lines would understate the claim, or go negative on a reversal.
  #
  # Amounts are written once per claim, from RemittanceAmounts, over every
  # line for that claim. The last line does not replace an earlier payment.
  # Duplicate remittances and reversals are netted there, in integer cents,
  # the same rule ReferralBillingReconciliation uses.
  #
  # Status comes from the latest status-setting line in that payment order,
  # which is not always the latest line. A line sets status when it is
  # marked "denied", or when its paid amount is a positive number of
  # subunits. A denial records that line's CARC/RARC codes (adjustment_codes)
  # through mark_denied!. A positive payment marks the claim paid. When no
  # line sets status, only the amounts are written.
  #
  # The batch's writes share one ClaimSubmission transaction. A line that
  # cannot be parsed raises, and every claim in the batch stays as it was.
  #
  # Free-text denial reasons on the line item are not stored: per ADR 0003
  # text is kept only as a vault token, and the codes already say why.
  #
  # Runs inside the caller's tenant context; line items whose claim is not
  # in that tenant are skipped, never matched across tenants. Each matched
  # claim counts once toward paid, denied, updated, or unknown. A line that
  # names no claim in this tenant counts as unmatched.
  class RemittanceProcessor
    Result = Struct.new(:paid, :denied, :updated, :unmatched, :unknown, keyword_init: true)

    def self.call(remittances, adapter: Corvid.adapter)
      new(adapter: adapter).call(remittances)
    end

    def initialize(adapter: Corvid.adapter)
      @adapter = adapter
    end

    def call(remittances)
      result = Result.new(paid: 0, denied: 0, updated: 0, unmatched: 0, unknown: 0)
      batch = Array(remittances)
      apply_with_history(claims_in(batch, result), batch, result)
      result
    end

    private

    # One fetch for the whole call. Nil is unknown: leave the claims alone
    # and do not fall back to summing the batch by itself.
    def apply_with_history(claims, batch, result)
      history = @adapter.fetch_remittances
      if history.nil?
        result.unknown = claims.size
        return
      end

      apply_batch(claims, history + batch, result)
    end

    def apply_batch(claims, remittances, result)
      ClaimSubmission.transaction do
        claims.each { |claim| tally(result, apply_claim(claim, remittances)) }
      end
    end

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
    # is not a match. Surrounding whitespace is not part of the identifier.
    def claim_for(item)
      claim_identifier = item[:claim_identifier].to_s.strip.presence
      claim_identifier && ClaimSubmission.find_by(claim_identifier: claim_identifier)
    end

    def apply_claim(claim, remittances)
      amounts = RemittanceAmounts.call(claim: claim, remittances: remittances)
      apply_status(claim, amounts) if amounts
    end

    # A later zero payment does not take back a paid status. An undated
    # denial sorts after a dated payment and does.
    def apply_status(claim, amounts)
      line = status_line(claim, amounts.lines)
      return write_amounts(claim, amounts) unless line
      return deny_claim(claim, amounts, line) if denied?(line)

      claim.update!(amounts.attributes.merge(status: "paid"))
      :paid
    end

    def status_line(claim, lines)
      lines.reverse_each.find { |line| sets_status?(claim, line) }
    end

    def sets_status?(claim, line)
      denied?(line) || positive_paid?(line[:paid_amount], claim)
    end

    def denied?(line)
      line[:status].to_s == "denied"
    end

    def write_amounts(claim, amounts)
      claim.update!(amounts.attributes)
      :updated
    end

    def deny_claim(claim, amounts, line)
      claim.assign_attributes(amounts.attributes)
      claim.mark_denied!(reason_codes: adjustment_codes(line))
      :denied
    end

    def positive_paid?(amount, claim)
      RemittanceAmounts.cents(
        amount, claim.currency_iso,
        claim_identifier: claim.claim_identifier, field: :paid_amount
      ).positive?
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
