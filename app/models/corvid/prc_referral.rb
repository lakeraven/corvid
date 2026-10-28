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
    # Deferred is absent here; a committed deferral syncs as CHS_STATUS_DEFAULT.
    # Cancelled has no code and is not synced.
    CHS_STATUS_MAP = { "authorized" => "A", "denied" => "D" }.freeze
    CHS_STATUS_DEFAULT = "P"
    # Authorize, deny, and defer only. In-progress states stay local.
    EHR_SYNCED_STATUSES = %w[authorized denied deferred].freeze

    belongs_to :case, class_name: "Corvid::Case"
    has_one :eligibility_checklist, dependent: :destroy, class_name: "Corvid::EligibilityChecklist"
    has_many :tasks, as: :taskable, dependent: :destroy, class_name: "Corvid::Task"
    has_many :alternate_resource_checks, dependent: :destroy, class_name: "Corvid::AlternateResourceCheck"
    has_many :committee_reviews, dependent: :destroy, class_name: "Corvid::CommitteeReview"
    # Fulfilment is a lifecycle distinct from authorization (see
    # Corvid::ReferralFulfilment) — no shared states with the `status` AASM
    # above, just its own append-only report trail hung off this referral.
    #
    # restrict, not destroy: the trail is the evidence that care was delivered.
    # Cascading a destroy through it would let deleting a referral rewrite the
    # record of what happened.
    has_many :fulfilment_reports, dependent: :restrict_with_error, class_name: "Corvid::ReferralFulfilmentReport"
    # nullify, not destroy: a claim outlives the referral that occasioned it —
    # it has its own lifecycle with the payer and its own financial record.
    has_many :claim_submissions, dependent: :nullify, class_name: "Corvid::ClaimSubmission"

    validates :referral_identifier, presence: true
    validates :referral_identifier, uniqueness: { scope: [ :tenant_identifier, :facility_identifier ] }

    # MedicalPriorityService writes only this. Null until a priority is assigned.
    # Same set as corvid_prc_referrals_priority_system_check (ADR 0002).
    PRIORITY_SYSTEMS = %w[corvid_v1].freeze

    # Optional "$", plain digits or comma-grouped thousands, optional cents.
    COMMITTEE_COST_FORMAT = /\A\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?\z/
    COMMITTEE_PRIORITY_FORMAT = /\A\d+\z/
    validates :priority_system, inclusion: { in: PRIORITY_SYSTEMS }, allow_nil: true

    # Referrals for a given patient. Joins the parent Case since the
    # patient_identifier lives there (the referral is case-scoped).
    # Eager-loads the case so callers iterating referrals don't N+1.
    scope :for_patient_identifier, ->(patient_identifier) {
      includes(:case).references(:case)
        .where(corvid_cases: { patient_identifier: patient_identifier })
    }

    # whiny_persistence pinned: aasm 6 flipped its default to true, which would
    # make a bang event on an invalid record raise instead of returning false.
    aasm column: :status, whiny_transitions: false, whiny_persistence: false do
      state :draft, initial: true
      state :submitted, :eligibility_review, :management_approval, :alternate_resource_review
      state :priority_assignment, :committee_review, :exception_review
      state :authorized, :denied, :deferred, :cancelled

      # Runs after a transition is chosen and before it is saved, for both
      # bang events and non-bang events later saved with save!. Creating a
      # row already in a terminal status, or update!(status:), is not an
      # event and does not mark a publication. The mark is kept only while
      # the change is still the AASM one: status differs from the database,
      # equals the marked state, and no status rewrite has replaced it.
      # update_columns and update_column drop it when they write status.
      # reload, restore_attributes, and dup drop it too.
      after_all_transitions :mark_pending_referral_publication

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

      # Re-verify in the event callback, not the guard. Guards are pure and
      # may_? would otherwise hit the payer on every check. AASM still runs
      # that callback when no transition leaves the current state, so each
      # callback checks from-states (ignoring guards) before any payer call.
      event :verify_alternate_resources, before: :reverify_before_verify_alternate_resources do
        transitions from: :alternate_resource_review, to: :priority_assignment,
                    guard: :alternate_resources_exhausted?
      end

      event :complete_priority_assignment, before: :reverify_before_complete_priority_assignment do
        transitions from: :priority_assignment, to: :committee_review, guard: :requires_committee?
        # The authorized sync is published once after commit
        # (publish_committed_referral_status); committee_review does not sync.
        transitions from: :priority_assignment, to: :authorized,
                    guard: :alternate_resources_exhausted?
      end

      event :authorize, before: :reverify_before_authorize do
        transitions from: [ :priority_assignment, :committee_review ], to: :authorized,
                    guard: :alternate_resources_exhausted?
      end

      event :mark_denied do
        transitions from: [ :eligibility_review, :exception_review, :priority_assignment, :committee_review ], to: :denied
      end

      event :mark_deferred, after: :record_deferred_determination do
        transitions from: [ :priority_assignment, :committee_review ], to: :deferred
      end

      # Cancellation is only valid while the referral is still in flight. The
      # four terminal states (authorized, denied, deferred, cancelled) are
      # genuine end states, so cancel omits them from its `from:` list —
      # otherwise a cancelled referral could be cancelled again (self-loop) and
      # the terminals would not be true end states.
      event :cancel do
        transitions from: %i[draft submitted eligibility_review management_approval
                             alternate_resource_review priority_assignment
                             committee_review exception_review],
                    to: :cancelled
      end
    end

    # The AASM callback marks authorize, deny, or defer. before_save
    # captures that mark, the tenant, and the provenance snapshot while
    # the change is still unsaved. after_save registers the commit and
    # rollback pair, and it runs only after the row is persisted, so a
    # later before_save that aborts does not leave a sync registered on
    # an outer transaction. Commit publishes once, inside the captured
    # tenant. A plain status write never marks a publication. In-progress
    # states are not synced. Cancelled has no CHS code and is not synced.
    # Rollback does not publish; it puts the mark back so a later save
    # of the same transition publishes once.
    before_save :capture_referral_publication
    after_save :register_referral_publication

    def service_request
      @service_request ||= Corvid.adapter.find_referral(referral_identifier) if referral_identifier.present?
    end

    # 42 CFR 136.61 — PRC pays last. True only when every alternate resource
    # is unavailable and current for today. A referral has no date of service;
    # the authorization date is the decision date.
    def alternate_resources_exhausted?
      AlternateResourceCheck.all_exhausted?(self, date_of_service: Date.current, as_of: Time.current)
    end

    # Refresh checks that are not current for the authorization date when
    # authorize can leave this state (priority_assignment or
    # committee_review). Cancelled, denied, draft, and any other state are
    # refused without a payer call. Event callbacks use reverify_for_event
    # for the same from-state rule. Returns true so an AASM before-callback
    # does not abort; the guard decides.
    #
    # Per ADR 0005, services inject adapter:. This model method still
    # defaults to Corvid.adapter (#264). CommitteeReviewSyncService passes
    # its injected adapter so re-verification does not use the global.
    def reverify_alternate_resources_for_decision(adapter: Corvid.adapter)
      refresh_stale_alternate_resources(adapter: adapter) if event_can_leave_state?(:authorize)
      true
    end

    # Sorted reasons authorization is refused. Resource type and status only;
    # patient, payer, and policy data never appear here (ADR 0003).
    def authorization_blockers
      by_type = alternate_resource_checks.reload.index_by(&:resource_type)
      AlternateResourceCheck::RESOURCE_TYPES.filter_map do |type|
        blocker_for(type, by_type[type])
      end.sort
    end

    # Why a committee approval must not authorize. An authorized
    # referral is already consistent with the approval, so a retried
    # sync may proceed. A state authorize cannot leave is named alone,
    # including draft, cancelled, and denied, even when checks are
    # stale — apply and sync refuse those without a payer call. From
    # priority_assignment or committee_review, open alternate resources
    # are authorization_blockers, same strings and order (ADR 0003).
    def committee_approval_blockers
      return [] if authorized?
      return [ "referral: #{status}" ] unless event_can_leave_state?(:authorize)
      return authorization_blockers unless alternate_resources_exhausted?
      return [] if may_authorize?

      [ "referral: #{status}" ]
    end

    # EHR cost when it is not nil, otherwise the local column. An unknown
    # cost or priority requires committee. Both costs absent does not.
    # A known priority requires review at 3+. Nil priority does too.
    def requires_committee?
      committee_cost_requires_review? || committee_priority_requires_review? || flagged_for_review?
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
      # During the permitted-events check (e.g. rendering available
      # transitions) the approver isn't known yet — offer the transition and
      # enforce dual control when it actually fires, once the caller has set
      # pending_approval_by. Firing without it still raises via
      # pending_approval_by! in record_management_approval.
      return true if pending_approval_by.blank?

      pending_approval_by != submitted_by_identifier
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
    # RCIS-first caching (ported from the predecessor app)
    # ----------------------------------------------------------------

    CACHE_STALENESS_THRESHOLD_HOURS = 1

    # -- medical priority caching ------------------------------------------

    def medical_priority_cache_stale?
      return true if medical_priority_cached_at.blank?

      medical_priority_cached_at < CACHE_STALENESS_THRESHOLD_HOURS.hours.ago
    end

    # Priority for a decision. The service request's level when it is
    # not nil, otherwise the local column. Blank and other present
    # values are kept. This is a read: it does not refresh the cache
    # the way cached_medical_priority does.
    def effective_medical_priority
      rcis_priority = service_request&.medical_priority_level
      rcis_priority.nil? ? medical_priority : rcis_priority
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
    # 72-hour notification rules (ported from the predecessor app)
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

    # A direct status write is not an AASM event. The write that lands
    # on the marked state is the AASM change. A later write that leaves
    # that state is a rewrite, and the mark cannot survive it. Assigning
    # the marked state again, with no rewrite in between, is still that
    # transition.
    def status=(value)
      note_referral_status_rewrite(value)
      super
      discard_pending_referral_publication_unless_current
    end

    def write_attribute(attr_name, value)
      note_referral_status_rewrite(value) if attr_name.to_s == "status"
      super
      discard_pending_referral_publication_unless_current if attr_name.to_s == "status"
    end

    # update_column calls update_columns. Both skip status= and
    # write_attribute, so a status write here drops the mark itself.
    # Otherwise a later update!(status:) would publish the stale event.
    def update_columns(attributes)
      wrote_status = attributes.key?(:status) || attributes.key?("status")
      result = super
      drop_referral_publication_mark if wrote_status
      result
    end

    # ActiveRecord reload refreshes columns only. Committee routing reads
    # priority and cost from the service-request memo, so a reload drops it
    # and takes the EHR's current service request on the next read. It also
    # drops any pending publication mark.
    def reload(...)
      super.tap do
        @service_request = nil
        reset_referral_publication_mark
      end
    end

    # dup copies instance variables, including a mark left by an unsaved
    # event. The copy is a new row and must not publish that event.
    def initialize_dup(other)
      super
      reset_referral_publication_mark
    end

    def restore_attributes(...)
      super
      discard_pending_referral_publication_unless_current
    end

    private

    def capture_referral_publication
      discard_pending_referral_publication_unless_current
      pending = @pending_referral_publication
      @referral_publication_to_register = nil
      return if pending.nil?

      @referral_publication_to_register = referral_publication_payload(pending)
    end

    def register_referral_publication
      captured = @referral_publication_to_register
      @referral_publication_to_register = nil
      return if captured.nil?

      pending, provenance_entities, tenant = captured
      @pending_referral_publication = nil
      return unless status.to_s == pending

      hold_referral_publication(pending, provenance_entities, tenant)
    end

    def referral_publication_payload(pending)
      entities = authorization_provenance_entities if pending == "authorized"
      [ pending, entities, Corvid::TenantContext.current_tenant_identifier ]
    end

    # Registered from after_save on the transaction that holds this save.
    # Commit publishes. Rollback puts the mark back and does not publish.
    # A committed savepoint carries both callbacks to its parent, so the
    # publish waits for the outermost commit and a rolled-back savepoint
    # never reaches it.
    def hold_referral_publication(pending, provenance_entities, tenant)
      transaction = self.class.current_transaction
      transaction.after_rollback { restore_pending_referral_publication(pending) }
      return unless status.to_s == pending

      transaction.after_commit do
        publish_committed_referral_status(pending, provenance_entities, tenant)
      end
    end

    def restore_pending_referral_publication(pending)
      @pending_referral_publication = pending
      @referral_status_rewritten_since_mark = false
    end

    # Kept only for an AASM change that is still the one about to be
    # saved: status differs from the database, equals the marked state,
    # and no rewrite has replaced that change.
    def discard_pending_referral_publication_unless_current
      return if referral_publication_still_pending?

      @pending_referral_publication = nil
    end

    def referral_publication_still_pending?
      pending = @pending_referral_publication
      return false if pending.nil? || @referral_status_rewritten_since_mark

      status.to_s == pending && status.to_s != status_in_database.to_s
    end

    # The write that first lands on the marked state is the AASM change.
    # A later write that changes status again is a rewrite. Assigning the
    # same value leaves the mark, so a rolled-back save can be saved again.
    def note_referral_status_rewrite(value)
      pending = @pending_referral_publication
      return if pending.nil?

      new_status = value.to_s
      return if status.to_s == new_status
      return if establishing_referral_publication?(new_status)

      @referral_status_rewritten_since_mark = true
    end

    def establishing_referral_publication?(new_status)
      status.to_s != @pending_referral_publication &&
        new_status == @pending_referral_publication &&
        !@referral_status_rewritten_since_mark
    end

    def drop_referral_publication_mark
      @pending_referral_publication = nil
      @referral_publication_to_register = nil
      @referral_status_rewritten_since_mark = true
    end

    def reset_referral_publication_mark
      @pending_referral_publication = nil
      @referral_publication_to_register = nil
      @referral_status_rewritten_since_mark = false
    end

    # Latest transition wins. In-flight and cancelled transitions clear a
    # mark left by an unsaved earlier event so only authorize, deny, and
    # defer are published.
    def mark_pending_referral_publication
      new_status = aasm.to_state.to_s
      @referral_status_rewritten_since_mark = false
      @pending_referral_publication = ehr_synced_status?(new_status) ? new_status : nil
      true
    end

    def publish_committed_referral_status(new_status, provenance_entities, tenant)
      if ehr_synced_status?(new_status)
        Corvid::TenantContext.with_tenant(tenant) do
          sync_status_to_ehr(new_status)
        end
      end
      return if provenance_entities.nil?

      AlternateResourceReverification.record!(
        self,
        activity: "UPDATE",
        entities: provenance_entities,
        tenant: tenant
      )
    end

    def ehr_synced_status?(status_value)
      EHR_SYNCED_STATUSES.include?(status_value.to_s)
    end

    def authorization_provenance_entities
      AlternateResourceReverification.snapshot_entities(alternate_resource_checks.reload)
    end

    def blocker_for(resource_type, check)
      return "#{resource_type}: not checked" if check.nil?
      return "#{resource_type}: not current" if unavailable_but_not_current?(check)
      return if check.exhausted_or_unavailable?

      detail = check.status.to_s.tr("_", " ")
      detail = "#{detail} (coordination of benefits not complete)" if check.enrolled?
      "#{resource_type}: #{detail}"
    end

    # Unavailable by status, but not a determination for the authorization
    # date. Resource type and a fixed reason only — no patient, payer, or
    # policy data (ADR 0003).
    def unavailable_but_not_current?(check)
      check.exhausted_or_unavailable? && !check.current_for?(Date.current, as_of: Time.current)
    end

    def reverify_before_verify_alternate_resources
      reverify_for_event(:verify_alternate_resources)
    end

    def reverify_before_complete_priority_assignment
      reverify_for_event(:complete_priority_assignment)
    end

    def reverify_before_authorize
      reverify_for_event(:authorize)
    end

    def reverify_for_event(event_name)
      refresh_stale_alternate_resources if event_can_leave_state?(event_name)
      true
    end

    def refresh_stale_alternate_resources(adapter: Corvid.adapter)
      AlternateResourceReverification.reverify_stale!(
        self, date_of_service: Date.current, as_of: Time.current, adapter: adapter
      )
    end

    # From-states only. Guards run after the refresh and must not be
    # consulted here, or a stale row would skip the payer call that
    # could make the guard pass.
    def event_can_leave_state?(event_name)
      event = self.class.aasm.state_machine.events[event_name]
      return false unless event

      event.transitions_from_state?(aasm.current_state)
    end

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

    # Money -> amount. Integer and BigDecimal as-is. Float via
    # BigDecimal(float.to_s). Anything else present is unknown (ADR 0004).
    def committee_cost_requires_review?
      dollars = parse_committee_cost(committee_cost_value)
      return false if dollars.nil?
      return true if dollars == :unknown

      dollars >= committee_threshold
    end

    def committee_cost_value
      ehr_cost = service_request&.estimated_cost
      ehr_cost.nil? ? estimated_cost : ehr_cost
    end

    def parse_committee_cost(value)
      return nil if value.nil?
      return value.amount if value.is_a?(Money)
      return value if value.is_a?(Integer) || value.is_a?(BigDecimal)
      return BigDecimal(value.to_s) if value.is_a?(Float)
      return parse_committee_cost_string(value) if value.is_a?(String)

      :unknown
    end

    def parse_committee_cost_string(value)
      stripped = value.strip
      return :unknown unless stripped.match?(COMMITTEE_COST_FORMAT)

      BigDecimal(stripped.delete(",").delete_prefix("$"))
    end

    # Integer as-is. ASCII digits, after strip, become an Integer.
    # Any other present value is unknown. This does not raise.
    def committee_priority_requires_review?
      priority = parse_committee_priority(effective_medical_priority)
      return true unless priority.is_a?(Integer)

      priority >= 3
    end

    def parse_committee_priority(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)
      return parse_priority_digits(value) if value.is_a?(String)

      :unknown
    end

    def parse_priority_digits(value)
      digits = value.strip
      return :unknown unless digits.match?(COMMITTEE_PRIORITY_FORMAT)

      digits.to_i
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

    def sync_status_to_ehr(status_value = status)
      return unless referral_identifier.present?

      chs_status = CHS_STATUS_MAP[status_value.to_s] || CHS_STATUS_DEFAULT
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
