# frozen_string_literal: true

module Corvid
  # Reconciles a claim's remittance against the referral it bills.
  #
  # Two facts have to hold together: the payer settled the bill, and there is a
  # record that the care was delivered. Payment says nothing about whether the
  # care happened, and a delivery report says nothing about money, so neither
  # alone is called reconciled.
  #
  # The claim and the referral are tied through ClaimSubmission#prc_referral
  # rather than matched by identifier here. Trusting the two arguments
  # independently would let a paid claim for one referral be reported as
  # reconciled against a different referral's delivered-care record.
  class ReferralBillingReconciliation
    Result = Struct.new(:referral_identifier, :status, :fulfilment_verified, :claim, keyword_init: true)

    # Raised when the claim passed to .reconcile! is not the one linked to the
    # referral passed alongside it.
    class AssociationMismatch < StandardError; end

    # Remittance line fields summed toward settlement, keyed by total name.
    TOTAL_FIELDS = {
      paid: :paid_amount, adjustment: :adjustment_amount,
      patient_responsibility: :patient_responsibility, denied: :denied_amount
    }.freeze
    private_constant :TOTAL_FIELDS

    def self.reconcile!(referral:, claim:, adapter: Corvid.adapter)
      new(adapter: adapter).reconcile!(referral: referral, claim: claim)
    end

    def initialize(adapter: Corvid.adapter)
      @adapter = adapter
    end

    # Reconciled needs remittance evidence read on this call. A stored paid
    # status and amounts are not enough on their own: the payer may have
    # reversed the payment since, and an unknown read cannot say otherwise.
    def reconcile!(referral:, claim:)
      ensure_claim_matches_referral!(referral, claim)

      # A clearinghouse rejection never reached the payer, so no remittance
      # answers it. A denial can still be paid on appeal, so it is re-read.
      evidence = claim.status == "rejected" ? false : apply_remittances!(claim)
      claim.reload

      fulfilment_verified = Corvid::ReferralFulfilment.billable_for_delivered_care?(referral)

      Result.new(
        referral_identifier: referral.referral_identifier,
        status: (evidence && settled?(claim) && fulfilment_verified) ? "reconciled" : "pending",
        fulfilment_verified: fulfilment_verified,
        claim: claim
      )
    end

    private

    def ensure_claim_matches_referral!(referral, claim)
      return if claim.prc_referral_id.present? && claim.prc_referral_id == referral.id

      raise AssociationMismatch,
        "Claim #{claim.id} (prc_referral_id=#{claim.prc_referral_id.inspect}) is not linked to " \
        "referral #{referral.referral_identifier} (id=#{referral.id}); refusing to reconcile"
    end

    # A stored paid status is not proof on its own: #mark_paid! and
    # #check_status! both set it without looking at the amounts. The claim
    # is settled only when it is paid and its stored amounts leave nothing
    # owed on what was billed.
    def settled?(claim)
      claim.paid? && claim.billed_amount_cents.to_i.positive? && !claim.balance_due.positive?
    end

    # The claim's amounts are recomputed from every remittance line for it
    # on each call, so reading the same remittances again never counts them
    # twice. A nil read is unknown, not "no remittances", and records nothing.
    # Returns whether any remittance line for the claim was applied.
    def apply_remittances!(claim)
      return false if claim.claim_identifier.blank?

      remittances = @adapter.fetch_remittances
      return false if remittances.nil?

      lines = matching_lines(claim, remittances)
      return false if lines.empty?

      totals = totals_in_cents(lines, claim.currency_iso)
      attrs = { paid_date: lines.last[:payment_date], status: resolved_status(claim, lines.last, totals) }
      attrs[:paid_amount_cents] = totals[:paid] if stated?(lines, :paid_amount)
      attrs[:patient_responsibility_cents] = totals[:patient_responsibility] if stated?(lines, :patient_responsibility)
      # A denied amount is an adjustment in 835 terms (a CAS segment), so it
      # is stored with the adjustments and #balance_due does not report the
      # denied portion as still owed.
      if stated?(lines, :adjustment_amount) || stated?(lines, :denied_amount)
        attrs[:adjustment_amount_cents] = totals[:adjustment] + totals[:denied]
      end

      claim.update!(attrs)
      true
    end

    # Every line for the claim across all remittances, oldest payment first.
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
        lines.sum { |line| cents(line[field], currency_iso) }
      end
    end

    def cents(value, currency_iso)
      return 0 if value.nil?

      Money.from_amount(BigDecimal(value.to_s), currency_iso).cents
    end

    def stated?(lines, field)
      lines.any? { |line| !line[field].nil? }
    end

    # The claim is settled only when the remittances account for what was
    # billed: payment, contractual adjustments, patient responsibility and
    # denied amounts together. Any positive payment used to close it, so a
    # $100 remittance against a $425 claim read as fully paid and the $325
    # balance quietly stopped being owed.
    #
    # A denial is an answer and is recorded as one: without this a denied
    # claim sits in its prior status indefinitely, indistinguishable from one
    # the payer has not responded to. A bill accounted for with nothing paid
    # by the payer or owed by the patient is a denial when the payer says so
    # or when only denied amounts cover it. Otherwise the most recent line
    # decides, so a payment on appeal after a denial can still settle the
    # claim, and a denied line beside a payment is a partial denial.
    #
    # STATUSES carries no partially-paid state, so a claim short of the bill
    # keeps its prior status, except that one recorded as paid is owed again
    # (a reversal took the money back) and returns to accepted.
    def resolved_status(claim, latest_line, totals)
      denied_line = latest_line[:status].to_s == "denied"
      billed = claim.billed_amount_cents.to_i
      collected = totals[:paid] + totals[:patient_responsibility]
      accounted = collected + totals[:adjustment] + totals[:denied]

      if billed.positive? && accounted >= billed
        return "denied" unless (collected + totals[:adjustment]).positive?
        return "denied" if denied_line && !collected.positive?

        return "paid"
      end
      return "denied" if denied_line

      claim.paid? ? "accepted" : claim.status
    end
  end
end
