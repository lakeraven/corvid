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

    class << self
      def reconcile!(referral:, claim:)
        ensure_claim_matches_referral!(referral, claim)

        apply_remittance!(claim) unless claim.paid? || claim.rejected?
        claim.reload

        fulfilment_verified = Corvid::ReferralFulfilment.billable_for_delivered_care?(referral)

        Result.new(
          referral_identifier: referral.referral_identifier,
          status: (claim.paid? && fulfilment_verified) ? "reconciled" : "pending",
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

      def apply_remittance!(claim)
        return if claim.claim_identifier.blank?

        line_item = find_line_item(claim)
        return unless line_item

        attrs = { paid_date: line_item[:payment_date] }
        attrs[:paid_amount] = line_item[:paid_amount] if line_item[:paid_amount]
        attrs[:adjustment_amount] = line_item[:adjustment_amount] if line_item[:adjustment_amount]
        attrs[:patient_responsibility] = line_item[:patient_responsibility] if line_item[:patient_responsibility]
        attrs[:status] = resolved_status(claim, line_item)

        claim.update!(attrs)
      end

      def find_line_item(claim)
        Corvid.adapter.fetch_remittances.each do |remittance|
          item = (remittance[:line_items] || []).find { |li| li[:claim_identifier] == claim.claim_identifier }
          return item.merge(payment_date: remittance[:payment_date]) if item
        end
        nil
      end

      # A denial is an answer and is recorded as one: without this a denied
      # claim sits in its prior status indefinitely, indistinguishable from one
      # the payer has not responded to.
      #
      # Otherwise the claim is settled only when the remittance accounts for
      # what was billed. Any positive payment used to close it, so a $100
      # remittance against a $425 claim read as fully paid and the $325 balance
      # quietly stopped being owed.
      def resolved_status(claim, line_item)
        return "denied" if line_item[:status].to_s == "denied"
        return "paid" if claim_settled?(claim, line_item)

        claim.status
      end

      # An 835 accounts for a billed amount across payment, contractual
      # adjustments, patient responsibility and denied lines. STATUSES carries
      # no partially-paid state, so anything short leaves the claim in its
      # prior status — outstanding — rather than recorded as settled.
      def claim_settled?(claim, line_item)
        billed = claim.billed_amount.to_f
        return false unless billed > 0
        return false unless line_item[:paid_amount].to_f > 0

        accounted = line_item[:paid_amount].to_f +
          line_item[:adjustment_amount].to_f +
          line_item[:patient_responsibility].to_f +
          line_item[:denied_amount].to_f

        accounted >= billed
      end
    end
  end
end
