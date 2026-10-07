# frozen_string_literal: true

module Corvid
  # Applies 835 remittances (as returned by Corvid.adapter.fetch_remittances)
  # to the claims they settle.
  #
  # The 835 is where a payer's adjudicated decision arrives, so it is the
  # source of truth for denials. A line item is a denial when the adapter marks
  # it status "denied"; its CARC/RARC codes (adjustment_codes) are recorded on
  # the claim so denial reasons can be counted. A line with money paid marks
  # the claim paid. Anything else only updates the amounts it carries.
  #
  # Free-text denial reasons on the line item are not stored: per ADR 0003 text
  # is kept only as a vault token, and the codes already say why.
  #
  # Runs inside the caller's tenant context; line items whose claim is not in
  # that tenant are skipped, never matched across tenants.
  class RemittanceProcessor
    Result = Struct.new(:paid, :denied, :updated, :unmatched, keyword_init: true)

    def self.call(remittances)
      new.call(remittances)
    end

    def call(remittances)
      result = Result.new(paid: 0, denied: 0, updated: 0, unmatched: 0)

      Array(remittances).each do |remittance|
        Array(remittance[:line_items]).each do |item|
          claim = ClaimSubmission.find_by(claim_identifier: item[:claim_identifier])
          unless claim
            result.unmatched += 1
            next
          end

          case apply(claim, item, remittance)
          when :denied then result.denied += 1
          when :paid then result.paid += 1
          else result.updated += 1
          end
        end
      end

      result
    end

    private

    def apply(claim, item, remittance)
      attrs = {}
      attrs[:paid_amount] = item[:paid_amount] if item[:paid_amount]
      attrs[:adjustment_amount] = item[:adjustment_amount] if item[:adjustment_amount]
      attrs[:patient_responsibility] = item[:patient_responsibility] if item[:patient_responsibility]
      attrs[:paid_date] = remittance[:payment_date] if remittance[:payment_date]

      if item[:status].to_s == "denied"
        claim.assign_attributes(attrs)
        claim.mark_denied!(reason_codes: adjustment_codes(item))
        :denied
      elsif item[:paid_amount].to_f > 0
        claim.update!(attrs.merge(status: "paid"))
        :paid
      else
        claim.update!(attrs)
        :updated
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
