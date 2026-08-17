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
    include CurrencyImmutable
    include Determinable
    include AASM

    monetize :estimated_cost_cents, with_model_currency: :currency_iso, allow_nil: true

    # CHS approval status codes for EHR sync.
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

    # Referrals for a given patient. Joins the parent Case since the
    # patient_identifier lives there (the referral is case-scoped).
    # Eager-loads the case so callers iterating referrals don't N+1.
    scope :for_patient_identifier, ->(patient_identifier) {
      includes(:case).references(:case)
        .where(corvid_cases: { patient_identifier: patient_identifier })
    }

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
                    guard: :approver_distinct_from_submitter?,
                    after: :record_management_approval
      end

      # Manager returns an incomplete/incorrect determination for correction.
      # Sends the referral back to eligibility_review; approval stays unset.
      event :reject_management, after: :record_management_rejection do
        transitions from: :management_approval, to: :eligibility_review
      end

      # An eligibility item edited after approval invalidates that approval —
      # the referral drops back to eligibility_review and must be re-approved
      # before it can advance toward authorization (approve-then-alter guard).
      event :return_to_eligibility_review do
        transitions from: [ :alternate_resource_review, :priority_assignment, :committee_review, :exception_review ],
                    to: :eligibility_review
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

      event :mark_deferred, after: [ :sync_status_to_ehr, :record_deferred_determination ] do
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
      # Money's `>=` is currency-aware (raises across mismatched currencies);
      # the threshold is a numeric (USD-equivalent dollar amount) by
      # convention, so coerce Money → BigDecimal-of-dollars for comparison.
      cost = service_request&.estimated_cost || estimated_cost
      cost_dollars = cost.respond_to?(:to_d) ? cost.to_d : cost
      priority = medical_priority
      (cost_dollars.present? && cost_dollars >= committee_threshold) ||
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

    # Dual control: the approving manager must not be the person who
    # submitted the referral. When no submitter was recorded (legacy /
    # system-submitted referrals) the check is a no-op.
    def approver_distinct_from_submitter?
      return true if submitted_by_identifier.blank?

      pending_approval_by.present? && pending_approval_by != submitted_by_identifier
    end

    def management_approved?
      eligibility_checklist&.management_approved || false
    end

    # Transient attributes for a management rejection (return-for-correction).
    attr_accessor :rejecting_by, :rejection_reason

    # Called by the checklist when a non-approval eligibility item changes
    # after approval — invalidates the approval by returning to review.
    def reopen_for_eligibility_change!
      return_to_eligibility_review! if may_return_to_eligibility_review?
    end

    # ----------------------------------------------------------------
    # RCIS-first caching (ported from rpms_redux)
    # ----------------------------------------------------------------

    CACHE_STALENESS_THRESHOLD_HOURS = 1

    # -- medical priority caching ------------------------------------------

    def medical_priority_cache_stale?
      return true if medical_priority_cached_at.blank?

      medical_priority_cached_at < CACHE_STALENESS_THRESHOLD_HOURS.hours.ago
    end

    def cached_medical_priority
      rcis_priority = service_request&.medical_priority_level

      if rcis_priority.present?
        refresh_medical_priority_cache!(rcis_priority)
        rcis_priority
      else
        medical_priority
      end
    end

    def refresh_medical_priority_from_rcis!
      @service_request = nil

      rcis_priority = service_request&.medical_priority_level

      if rcis_priority.present?
        refresh_medical_priority_cache!(rcis_priority)
        true
      else
        false
      end
    end

    # -- authorization number caching --------------------------------------

    def authorization_number_cache_stale?
      return true if authorization_number_cached_at.blank?

      authorization_number_cached_at < CACHE_STALENESS_THRESHOLD_HOURS.hours.ago
    end

    def cached_authorization_number
      rcis_auth = service_request&.identifier

      if rcis_auth.present?
        refresh_authorization_number_cache!(rcis_auth)
        rcis_auth
      else
        authorization_number
      end
    end

    def refresh_authorization_number_from_rcis!
      @service_request = nil

      rcis_auth = service_request&.identifier

      if rcis_auth.present?
        refresh_authorization_number_cache!(rcis_auth)
        true
      else
        false
      end
    end

    # ----------------------------------------------------------------
    # 72-hour notification rules (ported from rpms_redux)
    # ----------------------------------------------------------------

    def notification_within_72_hours?
      return true unless emergency_flag?
      return false unless notification_date.present?

      hours_since_notification <= notification_grace_period
    end

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

    # Get authorization number from RCIS (source of truth).
    # Falls back to local cache if RCIS unavailable.
    def generate_authorization_number
      cached_authorization_number
    end

    def refresh_medical_priority_cache!(priority_value)
      return if priority_value == medical_priority && !medical_priority_cache_stale?

      update_columns(
        medical_priority: priority_value,
        medical_priority_cached_at: Time.current
      )
    end

    def refresh_authorization_number_cache!(auth_number_value)
      return if auth_number_value == authorization_number && !authorization_number_cache_stale?

      update_columns(
        authorization_number: auth_number_value,
        authorization_number_cached_at: Time.current
      )
    end

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

    def record_management_rejection
      attrs = {
        management_rejected_at: Time.current,
        management_rejected_by_identifier: rejecting_by
      }
      if rejection_reason.present?
        attrs[:management_rejection_reason_token] = Corvid.adapter.store_text(
          case_token: self.case&.id&.to_s || "unknown",
          kind: :reason,
          text: rejection_reason
        )
      end
      update!(attrs)

      # A returned referral is not approved — clear any approval marker.
      eligibility_checklist&.clear_management_approval!
    end

    def record_deferred_determination
      record_determination!(outcome: "deferred", decision_method: "automated")
    end

    def sync_status_to_ehr
      return unless referral_identifier.present?

      chs_status = CHS_STATUS_MAP[status] || CHS_STATUS_DEFAULT
      Corvid.adapter.update_referral(referral_identifier, chs_approval_status: chs_status)
    rescue NotImplementedError, StandardError => e
      # NotImplementedError descends from ScriptError, not StandardError, so a
      # bare `rescue` misses it. Adapters that legitimately don't own referrals
      # (e.g. tribal-enrollment backends) raise NotImplementedError from
      # update_referral; the AASM transition must remain best-effort across them.
      Rails.logger.warn("PrcReferral: Failed to sync status to EHR: #{Corvid.sanitize_phi(e.message)}")
      false
    end
  end
end
