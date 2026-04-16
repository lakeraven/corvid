# frozen_string_literal: true

module Corvid
  # PRC referral state machine. Tracks the authorization workflow for a
  # ServiceRequest that lives in the EHR.
  #
  # referral_identifier is an opaque external token (per ADR 0001) — not
  # a Rails FK. Resolved via Corvid.adapter.find_referral.
  class PrcReferral < ::ActiveRecord::Base
    self.table_name = "corvid_prc_referrals"

    include TenantScoped
    include Determinable
    include AASM

    # CHS approval status codes (RPMS File 90001 field 1112).
    # Engine-owned mapping — no dependency on EHR-side constants.
    CHS_STATUS_MAP = { "authorized" => "A", "denied" => "D" }.freeze
    CHS_STATUS_DEFAULT = "P"

    belongs_to :case, class_name: "Corvid::Case"
    has_one :eligibility_checklist, dependent: :destroy, class_name: "Corvid::EligibilityChecklist"
    has_many :tasks, as: :taskable, dependent: :destroy, class_name: "Corvid::Task"
    has_many :alternate_resource_checks, dependent: :destroy, class_name: "Corvid::AlternateResourceCheck"
    has_many :committee_reviews, dependent: :destroy, class_name: "Corvid::CommitteeReview"

    validates :referral_identifier, presence: true
    validates :referral_identifier, uniqueness: { scope: [ :tenant_identifier, :facility_identifier ] }

    aasm column: :status, whiny_transitions: false do
      state :draft, initial: true
      state :submitted, :eligibility_review, :management_approval, :alternate_resource_review
      state :priority_assignment, :committee_review, :exception_review
      state :authorized, :denied, :deferred, :cancelled

      event :submit do
        transitions from: :draft, to: :submitted
      end

      event :begin_eligibility_review do
        transitions from: :submitted, to: :eligibility_review,
                    after: :auto_populate_checklist
      end

      event :request_management_approval do
        transitions from: :eligibility_review, to: :management_approval,
                    guard: :checklist_items_except_approval_complete?
      end

      event :approve_management do
        transitions from: :management_approval, to: :alternate_resource_review,
                    after: :record_management_approval
      end

      event :verify_alternate_resources do
        transitions from: :alternate_resource_review, to: :priority_assignment
      end

      event :complete_priority_assignment do
        transitions from: :priority_assignment, to: :committee_review, guard: :requires_committee?
        transitions from: :priority_assignment, to: :authorized
      end

      event :authorize, after: :sync_status_to_ehr do
        transitions from: [ :priority_assignment, :committee_review ], to: :authorized
      end

      event :mark_denied, after: :sync_status_to_ehr do
        transitions from: [ :eligibility_review, :exception_review, :priority_assignment, :committee_review ], to: :denied
      end

      event :mark_deferred, after: :sync_status_to_ehr do
        transitions from: [ :priority_assignment, :committee_review ], to: :deferred
      end

      event :cancel do
        transitions to: :cancelled
      end
    end

    def service_request
      @service_request ||= Corvid.adapter.find_referral(referral_identifier) if referral_identifier.present?
    end

    def requires_committee?
      cost = service_request&.estimated_cost || estimated_cost
      priority = medical_priority
      (cost.present? && cost >= committee_threshold) ||
        (priority.present? && priority >= 3) ||
        flagged_for_review?
    end

    def committee_threshold
      Corvid.adapter.get_site_params&.dig(:committee_threshold)&.to_d || 50_000
    end

    # Transient attribute for the manager who approved. Set before
    # firing approve_management, read by the after callback.
    attr_writer :pending_approval_by

    def pending_approval_by
      @pending_approval_by
    end

    def pending_approval_by!
      @pending_approval_by or raise ArgumentError,
        "pending_approval_by must be set before approve_management!"
    end

    def checklist_items_except_approval_complete?
      eligibility_checklist&.items_except_approval_complete? || false
    end

    # ----------------------------------------------------------------
    # 72-hour notification rules (ported from rpms_redux)
    # ----------------------------------------------------------------

    def notification_status
      return "not_required" unless emergency_flag?
      return "missing" if notification_date.nil?

      hours_since_notification <= notification_grace_period ? "timely" : "late"
    end

    def hours_since_notification
      return nil unless notification_date
      ((Time.current - notification_date) / 1.hour).round
    end

    def notification_grace_period
      Corvid.adapter.get_site_params&.dig(:notification_grace_period) || 72
    end

    def requires_exception_review?
      return false unless emergency_flag?
      return true if notification_date.nil?

      hours_since_notification > notification_grace_period
    end

    def document_late_notification!(reason:, documented_by:)
      update!(
        late_notification_reason_token: Corvid.adapter.store_text(
          case_token: self.case&.id&.to_s || "unknown",
          kind: :reason,
          text: reason
        ),
        late_notification_documented_at: Time.current,
        late_notification_documented_by_identifier: documented_by
      )
    end

    def approve_exception_review!(rationale:, approved_by:)
      update!(
        exception_approved: true,
        exception_rationale_token: Corvid.adapter.store_text(
          case_token: self.case&.id&.to_s || "unknown",
          kind: :rationale,
          text: rationale
        ),
        exception_reviewed_at: Time.current,
        exception_reviewed_by_identifier: approved_by
      )
    end

    def deny_exception_review!(rationale:, denied_by:)
      update!(
        exception_approved: false,
        exception_rationale_token: Corvid.adapter.store_text(
          case_token: self.case&.id&.to_s || "unknown",
          kind: :rationale,
          text: rationale
        ),
        exception_reviewed_at: Time.current,
        exception_reviewed_by_identifier: denied_by
      )
      record_determination!(
        outcome: "denied",
        decision_method: "staff_review",
        determined_by_identifier: denied_by
      )
      mark_denied! if may_mark_denied?
    end

    private

    def auto_populate_checklist
      Corvid::EligibilityChecklistService.populate!(self)
      create_exception_review_task_if_needed
    rescue => e
      Rails.logger.warn("PrcReferral: Failed to auto-populate checklist: #{e.message}")
    end

    def create_exception_review_task_if_needed
      return unless requires_exception_review?

      tasks.create!(
        tenant_identifier: tenant_identifier,
        facility_identifier: facility_identifier,
        description: "Exception review required: late notification (#{hours_since_notification || 'missing'} hours)",
        priority: :urgent
      )
    end

    def record_management_approval
      return unless eligibility_checklist

      eligibility_checklist.verify_item!(
        :management_approved,
        by: pending_approval_by!
      )
    end

    def sync_status_to_ehr
      return unless referral_identifier.present?

      chs_status = CHS_STATUS_MAP[status] || CHS_STATUS_DEFAULT
      Corvid.adapter.update_referral(referral_identifier, chs_approval_status: chs_status)
    rescue => e
      Rails.logger.warn("PrcReferral: Failed to sync status to EHR: #{Corvid.sanitize_phi(e.message)}")
      false
    end
  end
end
