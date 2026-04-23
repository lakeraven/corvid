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

    validates :committee_date, presence: true
    validates :rationale_token, presence: true, if: -> { denied? || deferred? }
    validates :approved_amount, presence: true, if: -> { approved? || modified? }
    validates :appeal_instructions_token, presence: true, if: :denied?

    scope :upcoming, -> { where(decision: "pending").where("committee_date >= ?", Date.current) }
    scope :finalized, -> { where.not(decision: "pending") }
    scope :chronological, -> { order(committee_date: :asc) }
    scope :reverse_chronological, -> { order(committee_date: :desc) }

    before_save :set_appeal_deadline, if: -> { denied? && appeal_deadline.nil? }

    def reviewer
      Corvid.adapter.find_practitioner(reviewer_identifier) if reviewer_identifier.present?
    end

    def finalized?
      !pending?
    end

    def approved_or_modified?
      approved? || modified?
    end

    def requires_followup?
      deferred? || modified?
    end

    def decision_summary
      case decision
      when "pending"  then "Pending committee review"
      when "approved" then "Approved - $#{approved_amount}"
      when "denied"   then "Denied"
      when "deferred" then "Deferred"
      when "modified" then "Approved with modifications - $#{approved_amount}"
      end
    end

    def apply_to_referral!
      return if pending?

      case decision
      when "approved", "modified" then prc_referral.authorize!
      when "denied"               then prc_referral.mark_denied!
      when "deferred"             then prc_referral.mark_deferred!
      end
    end

    private

    def set_appeal_deadline
      self.appeal_deadline = committee_date + 30.days
    end
  end
end
