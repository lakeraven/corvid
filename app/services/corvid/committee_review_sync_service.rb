# frozen_string_literal: true

module Corvid
  # Syncs committee review decisions to the EHR via adapter.
  #
  # Per #222 / ADR 0005: the adapter is injected per-instance rather
  # than reached via the `Corvid.adapter` global. The class-method form
  # accepts an `adapter:` kwarg (defaulting to `Corvid.adapter`) so
  # existing call sites keep working while tests and per-tenant code
  # paths can swap in their own adapters without mutating global state.
  class CommitteeReviewSyncService
    def initialize(adapter: Corvid.adapter)
      @adapter = adapter
    end

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
        { success: false, error: "Backend update failed" }
      end
    rescue => e
      { success: false, error: Corvid.sanitize_phi(e.message) }
    end

    # KNOWN LIMITATION (#264): the `apply_to_referral!` half drives AASM
    # state transitions on PrcReferral whose `after:` callbacks call
    # `Corvid.adapter.update_referral` directly. Until #264 lands the
    # apply half is NOT routed through the injected `@adapter` — the
    # `sync_decision` half is. Per-tenant adapter routing for the
    # combined flow isn't safe yet; see ADR 0005 §"Known limitation".
    def sync_and_apply!(committee_review)
      sync_result = sync_decision(committee_review)
      backend_synced = sync_result[:success]

      referral_updated = false
      begin
        committee_review.apply_to_referral!
        referral_updated = true
      rescue => e
        Rails.logger.warn("CommitteeReviewSyncService: apply_to_referral! failed: #{Corvid.sanitize_phi(e.message)}")
      end

      {
        success: backend_synced && referral_updated,
        backend_synced: backend_synced,
        referral_updated: referral_updated,
        sync_pending: !backend_synced
      }
    end

    # Class-method shims for backward compatibility. Existing callers
    # `Corvid::CommitteeReviewSyncService.sync_decision(review)` keep
    # working unchanged; new callers can pass `adapter:` to inject.
    class << self
      def sync_decision(committee_review, adapter: Corvid.adapter)
        new(adapter: adapter).sync_decision(committee_review)
      end

      def sync_and_apply!(committee_review, adapter: Corvid.adapter)
        new(adapter: adapter).sync_and_apply!(committee_review)
      end
    end

    private

    def missing_referral_identifier?(committee_review)
      committee_review.prc_referral&.referral_identifier.blank?
    end

    def build_update_params(committee_review)
      case committee_review.decision
      when "approved", "modified"
        # The EHR/adapter wire format takes a numeric amount, not a Money;
        # convert at the boundary per ADR 0004.
        { committee_decision: "APPROVED", approved_amount: committee_review.approved_amount&.to_d, reviewer_identifier: committee_review.reviewer_identifier }
      when "denied"
        { committee_decision: "DENIED", reviewer_identifier: committee_review.reviewer_identifier }
      when "deferred"
        { committee_decision: "DEFERRED", reviewer_identifier: committee_review.reviewer_identifier }
      else
        {}
      end
    end

    def update_ehr(identifier, params)
      @adapter.update_referral(identifier, params)
    end

    def build_success_result(committee_review)
      result = {
        success: true,
        synced_at: Time.current,
        committee_date: committee_review.committee_date
      }

      case committee_review.decision
      when "approved", "modified"
        result[:backend_status] = "AUTHORIZED"
        # synced_amount is part of the result struct surface, not the
        # internal Money type — emit numeric for downstream callers.
        result[:synced_amount] = committee_review.approved_amount&.to_d
      when "denied"
        result[:backend_status] = "DENIED"
        result[:denial_reason] = @adapter.fetch_text(committee_review.rationale_token) if committee_review.rationale_token.present?
      when "deferred"
        result[:backend_status] = "PENDING"
        result[:defer_reason] = @adapter.fetch_text(committee_review.rationale_token) if committee_review.rationale_token.present?
      end

      # Count synced items
      result[:conditions_synced] = count_token_items(committee_review.conditions_token)
      result[:attendees_synced] = count_token_items(committee_review.attendees_token)

      result
    end

    def count_token_items(token)
      return 0 unless token.present?
      data = @adapter.fetch_text(token)
      data.is_a?(Array) ? data.size : 0
    rescue
      0
    end
  end
end
