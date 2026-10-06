# frozen_string_literal: true

module Corvid
  # corvid#595: reconciles a claim's remittance against the referral it
  # bills, keyed through the structural ClaimSubmission#prc_referral
  # association rather than patient_identifier alone. Reconciliation is
  # only "reconciled" when BOTH the claim is paid AND fulfilment recorded
  # delivered care — payment alone (without a delivery record) is not
  # proof of anything either, so it does not get called reconciled.
  class ReferralBillingReconciliation
    Result = Struct.new(:referral_identifier, :status, :fulfilment_verified, :claim, keyword_init: true)

    # Raised when the claim passed to #reconcile! is not structurally
    # linked to the referral passed alongside it (PR #598 review): the
    # two arguments were previously trusted independently, so a paid
    # claim for one referral could be reported reconciled against a
    # different referral's delivered-care fact.
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

      # Same matching/apply logic as the existing remittance-polling step
      # ("I process the remittance" in billing_shared_steps.rb), scoped to
      # one claim rather than every remittance in the adapter.
      def apply_remittance!(claim)
        return unless claim.claim_identifier.present?

        remittance = Corvid.adapter.fetch_remittances.find do |rem|
          (rem[:line_items] || []).any? { |item| item[:claim_identifier] == claim.claim_identifier }
        end
        return unless remittance

        line_item = remittance[:line_items].find { |item| item[:claim_identifier] == claim.claim_identifier }
        return unless line_item

        attrs = { paid_date: remittance[:payment_date] }
        attrs[:paid_amount] = line_item[:paid_amount] if line_item[:paid_amount]
        attrs[:adjustment_amount] = line_item[:adjustment_amount] if line_item[:adjustment_amount]
        attrs[:patient_responsibility] = line_item[:patient_responsibility] if line_item[:patient_responsibility]
        attrs[:status] = line_item[:paid_amount].to_f > 0 ? "paid" : claim.status
        claim.update!(attrs)
      end
    end
  end
end
