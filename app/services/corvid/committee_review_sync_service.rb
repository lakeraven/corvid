# frozen_string_literal: true

module Corvid
  # Syncs committee review decisions to the EHR via adapter.
  class CommitteeReviewSyncService
    class << self
      def sync_decision(committee_review)
        return { success: false, error: "Cannot sync pending decision" } if committee_review.pending?
        return { success: false, error: "Missing referral IEN" } if missing_referral_identifier?(committee_review)

        prc_referral = committee_review.prc_referral
        identifier = prc_referral.referral_identifier
        params = build_update_params(committee_review)

        success = update_ehr(identifier, params)

        if success
          build_success_result(committee_review)
        else
          { success: false, error: "RPMS update failed" }
        end
      rescue => e
        { success: false, error: Corvid.sanitize_phi(e.message) }
      end

      def sync_and_apply!(committee_review)
        sync_result = sync_decision(committee_review)
        rpms_synced = sync_result[:success]

        referral_updated = false
        begin
          committee_review.apply_to_referral!
          referral_updated = true
        rescue => e
          Rails.logger.warn("CommitteeReviewSyncService: apply_to_referral! failed: #{e.message}")
        end

        {
          success: rpms_synced && referral_updated,
          rpms_synced: rpms_synced,
          referral_updated: referral_updated,
          sync_pending: !rpms_synced
        }
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

      def build_success_result(committee_review)
        result = {
          success: true,
          synced_at: Time.current,
          committee_date: committee_review.committee_date
        }

        case committee_review.decision
        when "approved", "modified"
          result[:rpms_status] = "AUTHORIZED"
          result[:synced_amount] = committee_review.approved_amount
        when "denied"
          result[:rpms_status] = "DENIED"
          result[:denial_reason] = Corvid.adapter.fetch_text(committee_review.rationale_token) if committee_review.rationale_token.present?
        when "deferred"
          result[:rpms_status] = "PENDING"
          result[:defer_reason] = Corvid.adapter.fetch_text(committee_review.rationale_token) if committee_review.rationale_token.present?
        end

        # Count synced items
        result[:conditions_synced] = count_token_items(committee_review.conditions_token)
        result[:attendees_synced] = count_token_items(committee_review.attendees_token)

        result
      end

      def count_token_items(token)
        return 0 unless token.present?
        data = Corvid.adapter.fetch_text(token)
        data.is_a?(Array) ? data.size : 0
      rescue
        0
      end
    end
  end
end
