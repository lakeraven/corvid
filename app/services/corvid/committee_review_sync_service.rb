# frozen_string_literal: true

module Corvid
  # Syncs committee review decisions to the EHR via adapter.
  class CommitteeReviewSyncService
    class << self
      def sync_decision(committee_review)
        return { success: false, error: "pending" } if committee_review.pending?
        return { success: false, error: "missing referral identifier" } if missing_referral_identifier?(committee_review)

        prc_referral = committee_review.prc_referral
        identifier = prc_referral.referral_identifier
        params = build_update_params(committee_review)

        success = update_ehr(identifier, params)

        if success
          { success: true, synced_amount: committee_review.approved_amount }
        else
          { success: false, error: "EHR update failed" }
        end
      rescue => e
        { success: false, error: Corvid.sanitize_phi(e.message) }
      end

      private

      def missing_referral_identifier?(committee_review)
        committee_review.prc_referral&.referral_identifier.blank?
      end

      def build_update_params(committee_review)
        case committee_review.decision
        when "approved", "modified"
          { committee_decision: "APPROVED", approved_amount: committee_review.approved_amount, reviewer_identifier: committee_review.reviewer_identifier }
        when "denied"
          { committee_decision: "DENIED", reviewer_identifier: committee_review.reviewer_identifier }
        when "deferred"
          { committee_decision: "DEFERRED", reviewer_identifier: committee_review.reviewer_identifier }
        else
          {}
        end
      end

      def update_ehr(identifier, params)
        Corvid.adapter.update_referral(identifier, params)
      end
    end
  end
end
