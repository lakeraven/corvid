# frozen_string_literal: true

module Corvid
  class CommitteeReview < ::ActiveRecord::Base
    self.table_name = "corvid_committee_reviews"

    include TenantScoped

    belongs_to :prc_referral, class_name: "Corvid::PrcReferral"

    enum :decision, {
      pending: "pending",
      approved: "approved",
      denied: "denied",
      deferred: "deferred",
      modified: "modified"
    }

    scope :upcoming, -> { where(decision: "pending").where("committee_date >= ?", Date.current) }
    scope :finalized, -> { where.not(decision: "pending") }

    def reviewer
      Corvid.adapter.find_practitioner(reviewer_identifier) if reviewer_identifier.present?
    end

    def finalized?
      !pending?
    end

    def apply_to_referral!
      return if pending?

      case decision
      when "approved", "modified" then prc_referral.authorize!
      when "denied"               then prc_referral.mark_denied!
      when "deferred"             then prc_referral.mark_deferred!
      end
    end
  end
end
