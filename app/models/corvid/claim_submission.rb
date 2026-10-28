# frozen_string_literal: true

module Corvid
  # Tracks 837P/I/D claims through lifecycle from draft to paid.
  # Ported from the predecessor app. Uses adapter pattern for clearinghouse
  # communication — a Clearinghouse adapter is one implementation, maintained
  # outside this engine (vendor adapters live in private repos).
  class ClaimSubmission < ::ActiveRecord::Base
    self.table_name = "corvid_claim_submissions"

    include TenantScoped
    include CurrencyImmutable

    monetize :billed_amount_cents, with_model_currency: :currency_iso, allow_nil: true
    monetize :paid_amount_cents, with_model_currency: :currency_iso, allow_nil: true
    monetize :adjustment_amount_cents, with_model_currency: :currency_iso, allow_nil: true
    monetize :patient_responsibility_cents, with_model_currency: :currency_iso, allow_nil: true
    monetize :state_share_cents, with_model_currency: :currency_iso, allow_nil: true
    monetize :county_share_cents, with_model_currency: :currency_iso, allow_nil: true

    STATUSES = %w[draft submitted accepted rejected paid denied appealed error].freeze
    CLAIM_TYPES = %w[professional institutional dental].freeze
    # Draft has not been sent. Error has not been sent unless the row
    # already stores a claim_identifier: the adapter identified the claim.
    # submitted_at alone does not make an error row sent. A plain save
    # cannot move a PRC-linked claim from an unsent status into a sent
    # status, cannot set status to "submitted" from any status, and cannot
    # write claim_identifier or submitted_at on an unsent linked claim.
    # The stored prc_referral_id counts as linked even when this save
    # clears the association. A plain save also cannot attach a claim
    # that already carries sent markers or a sent status to a referral.
    # An already-sent unlinked claim is not resolved when referral_identifier
    # is unchanged. For that skip, stored claim_identifier, stored
    # submitted_at, or a stored sent status counts, including submitted_at
    # on an error row, so a referral entered later does not block
    # check_status!, payment, remittance, or a plain edit. Changing
    # referral_identifier still
    # resolves and is refused. Assigning prc_referral is refused the
    # same way. Unsent claims and new rows still resolve a blank link.
    # submit! and mark_submitted! are the only paths that write those
    # markers or enter "submitted" from an unsent row, and they re-run
    # the gates. check_status! may record "submitted" on a claim that was
    # already sent. Later moves among sent statuses, including an error
    # that was actually sent, do not depend on submitted_at. A row created
    # already sent is a historical import and is left unstamped.
    UNSENT_STATUSES = %w[draft error].freeze
    SENT_STATUSES = %w[submitted accepted rejected paid denied appealed].freeze
    SENT_MARKER_MESSAGE = "must be set with submit! or mark_submitted!"

    # Raised by #submit! when this claim bills a PRC referral that has not been
    # authorized. PRC authorizes before care is purchased, so billing an
    # unauthorized referral bills care the programme never agreed to buy.
    class ReferralNotAuthorized < StandardError; end

    # Raised by #submit! and #mark_submitted! when a pending Medicaid
    # application may still cover the service, or that window cannot be
    # determined. #reason is inside_retroactive_window or
    # window_undetermined. The message names the reason and carries no
    # patient data (ADR 0003).
    class HeldForPendingMedicaid < StandardError
      INSIDE_RETROACTIVE_WINDOW = "inside_retroactive_window"
      WINDOW_UNDETERMINED = "window_undetermined"

      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("pending Medicaid application holds this claim: #{reason}")
      end
    end

    # Raised by #submit! and #mark_submitted! when the record has unsaved
    # edits. with_lock would raise RuntimeError and send nothing; this
    # names the refusal. Basis edits are refused separately, as an
    # undetermined Medicaid window, before this runs.
    class UnsavedChanges < StandardError; end

    # Raised by #submit! and #override_medicaid_hold! while
    # submission_outcome_unknown_at is set. The clearinghouse may
    # already have accepted the claim. Confirm it was not sent, or
    # mark it submitted, before another send or override.
    # The reported name is the leaf. Callers match that string, and
    # Module#name would otherwise be the full nesting.
    class SubmissionOutcomeUnknown < StandardError
      def self.name
        "SubmissionOutcomeUnknown"
      end

      def initialize
        super("submission outcome is unknown until it is reconciled")
      end
    end

    # Raised by #submit! when spending a Medicaid hold override would
    # run inside any open transaction, joinable or not. That caller
    # could roll the spend back after the clearinghouse had accepted
    # the claim. Override submits must be top-level.
    class OverrideRequiresTopLevelSubmit < StandardError
      def initialize
        super("spending a Medicaid hold override requires a top-level submit!")
      end
    end

    # Raised when this claim bills a PRC referral whose alternate-resource
    # checks are not current, exhausted determinations for service_date.
    # A missing service date fails closed. No patient, payer, or policy data.
    class AlternateResourcesNotCurrent < StandardError
      def initialize(message = "Alternate resource checks are not current for the date of service")
        super
      end
    end

    # The referral this claim bills, where there is one. Optional: claims
    # billed outside the referral workflow, and legacy rows the backfill could
    # not match unambiguously, carry no reference.
    belongs_to :prc_referral, class_name: "Corvid::PrcReferral", optional: true

    validates :patient_identifier, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :claim_type, inclusion: { in: CLAIM_TYPES }
    validate :never_submitted_claim_stays_unsubmitted
    validate :never_sent_claim_markers_only_through_submission
    validate :medicaid_hold_override_not_assigned_directly
    validate :medicaid_hold_override_all_or_none
    validate :submission_outcome_unknown_not_assigned_directly

    # Written only by override_medicaid_hold!. Cleared when the hold's
    # basis changes, and consumed by the submit! or mark_submitted! that
    # the override released. A direct write is invalid.
    MEDICAID_HOLD_OVERRIDE_COLUMNS = %i[
      medicaid_hold_override_reason_token
      medicaid_hold_override_by_identifier
      medicaid_hold_overridden_at
    ].freeze
    private_constant :MEDICAID_HOLD_OVERRIDE_COLUMNS

    # Statuses that close a Medicaid application. pending_enrollment
    # still holds with no application_date. Any other status holds only
    # when an application_date is recorded.
    MEDICAID_APPLICATION_ENDED_STATUSES = %w[denied enrolled coordinated exhausted].freeze
    private_constant :MEDICAID_APPLICATION_ENDED_STATUSES

    # A plain save cannot move a claim that has never been sent into
    # submitted, accepted, or paid, and cannot write claim_identifier
    # or submitted_at while the stored status is still unsent. Never
    # sent means both of those are still blank. Creating a row that is
    # already submitted, accepted, or paid stays allowed. That row may
    # record claim_identifier through a plain save and may move among
    # those statuses. Leaving one of them records submitted_at when it
    # was missing, so the return trip is not a first send.
    PAYABLE_SENT_STATUSES = %w[submitted accepted paid].freeze
    private_constant :PAYABLE_SENT_STATUSES

    # Mixed into the advisory-lock hash. The SQL and any error carry
    # only the resulting integers, never the tenant or patient token.
    MEDICAID_SUBMISSION_LOCK_PREFIX = "corvid.medicaid_submission.v1"
    private_constant :MEDICAID_SUBMISSION_LOCK_PREFIX

    # The link is derived from referral_identifier + facility_identifier +
    # patient_identifier, so it is recomputed whenever any of those change.
    # Resolving only a blank link left an edited claim pointing at the
    # referral it used to name: #submit! checked that one's authorization
    # while #to_claim_data sent the new identifier to the payer.
    # A blank link on a claim that is already sent is not one of those
    # changes. Resolving it would attach a referral created later, and
    # the ungated-sent guard would then reject a save that never touched
    # the referral. referral_identifier still recomputes that link.
    before_validation :resolve_prc_referral_from_identifier,
      if: :referral_link_inputs_changed?

    # Every path into rejected or denied (submit!, check_status!, the mark_*
    # helpers, remittance processing) records when it first happened, so the
    # KPIs above still count the claim after its status moves on.
    before_save :stamp_rejection_and_denial_times, if: :will_save_change_to_status?
    before_save :preserve_prior_sent_status, if: :leaving_unrecorded_sent_status?
    # After validation, so this clear is not a direct write of the
    # override columns. A caller who assigns those columns still fails.
    before_save :clear_medicaid_hold_override_when_basis_changes
    # Provenance is registered on the transaction that holds this save.
    # The check payload and the decision's tenant are captured here;
    # delivery runs when that transaction commits, inside the captured
    # tenant. A rolled-back savepoint drops the callback even if an outer
    # transaction commits. A hook failure does not undo the submission.
    # The gate flag is not a publication mark: a later plain save does
    # not publish a submission that rolled back.
    before_save :schedule_submission_provenance

    validate :submission_status_requires_gate, on: :update
    validate :unsent_linked_claim_cannot_gain_sent_markers, on: :update
    validate :cannot_attach_ungated_sent_claim, on: :update

    scope :by_status, ->(status) { where(status: status) }
    scope :pending, -> { where(status: %w[submitted accepted]) }
    scope :paid, -> { where(status: "paid") }
    # A rejection is a front-end refusal before adjudication (999 / 277CA):
    # fix the claim and resubmit. A denial is the payer's adjudicated decision
    # not to pay (835 CARC/RARC): appeal or write off. They are different work
    # queues and different KPIs, so the scopes keep them apart.
    scope :rejected, -> { where(status: "rejected") }
    scope :denied, -> { where(status: "denied") }
    scope :rejected_or_denied, -> { where(status: %w[rejected denied]) }
    scope :professional, -> { where(claim_type: "professional") }
    scope :institutional, -> { where(claim_type: "institutional") }
    scope :for_patient, ->(id) { where(patient_identifier: id) }
    scope :for_referral, ->(id) { where(referral_identifier: id) }
    scope :needs_status_check, ->(max_age = 1.hour) { pending.where("last_checked_at IS NULL OR last_checked_at < ?", max_age.ago) }
    scope :in_date_range, ->(range) { where(service_date: range) }

    # Per ADR 0004: aggregations across rows are bucketed by currency
    # so mixed-currency tenants never auto-FX. Each helper returns
    # { "USD" => Money(...), "EUR" => Money(...), ... }; an empty
    # scope returns {}.
    def self.totals_billed_by_currency
      group(:currency_iso).sum(:billed_amount_cents).each_with_object({}) do |(iso, cents), out|
        out[iso] = Money.new(cents, iso)
      end
    end

    def self.totals_paid_by_currency
      group(:currency_iso).sum(:paid_amount_cents).each_with_object({}) do |(iso, cents), out|
        out[iso] = Money.new(cents, iso)
      end
    end

    # KPI helpers. Each is a percentage of the current scope, so callers can
    # narrow first: ClaimSubmission.in_date_range(range).where(payer_identifier: p).denial_rate
    #
    # They read rejected_at / denied_at rather than status, because status
    # moves on (a rejected claim is resubmitted, a denied claim is appealed and
    # paid) while the fact that it was rejected or denied still counts.

    # Share of claims sent to the clearinghouse that were rejected before
    # adjudication at least once.
    def self.rejection_rate
      sent = where.not(submitted_at: nil)
      percentage(sent.where.not(rejected_at: nil), of: sent)
    end

    # Share of claims the payer adjudicated (paid, or denied at least once)
    # that were denied at least once.
    def self.denial_rate
      adjudicated = where(status: "paid").or(where.not(denied_at: nil))
      percentage(adjudicated.where.not(denied_at: nil), of: adjudicated)
    end

    # Share of claims with an outcome that were paid without ever being
    # rejected or denied: the claim went out once and came back paid.
    def self.first_pass_rate
      outcome = where(status: "paid").or(where.not(rejected_at: nil)).or(where.not(denied_at: nil))
      percentage(where(status: "paid", rejected_at: nil, denied_at: nil), of: outcome)
    end

    # Share of finalized claims (paid, rejected or denied) that are paid.
    def self.payment_rate
      percentage(where(status: "paid"), of: where(status: %w[paid rejected denied]))
    end

    # Deprecated: this was always paid / (paid + rejected + denied), which is a
    # payment rate, not an acceptance rate. Use payment_rate, or
    # rejection_rate for front-end acceptance.
    def self.acceptance_rate
      payment_rate
    end

    def self.percentage(subset, of:)
      total = of.count
      return 0.0 if total == 0

      (subset.count.to_f / total * 100).round(1)
    end
    private_class_method :percentage

    def professional?
      claim_type == "professional"
    end

    def institutional?
      claim_type == "institutional"
    end

    def submitted?
      status == "submitted"
    end

    def paid?
      status == "paid"
    end

    def rejected?
      status == "rejected"
    end

    def denied?
      status == "denied"
    end

    def rejected_or_denied?
      %w[rejected denied].include?(status)
    end

    def pending?
      %w[submitted accepted].include?(status)
    end

    def mark_submitted!(claim_identifier:)
      # Same gate order as submit!: authorization, then the
      # alternate-resource re-verification, before the row lock.
      prepare_medicaid_hold_submission!
      enforce_referral_authorization_gate!
      enforce_alternate_resources_current!
      discard_resolved_referral_link!
      refuse_unsaved_claim_changes!
      with_medicaid_submission_lock { record_marked_submission!(claim_identifier) }
    end

    def mark_paid!(paid_amount:)
      update!(status: "paid", paid_amount: paid_amount)
    end

    # Front-end rejection (999 / 277CA). reason_token is a vault token for the
    # rejection reason text.
    def mark_rejected!(reason_token:)
      update!(status: "rejected", rejection_reason_token: reason_token)
    end

    # Adjudicated denial (835). reason_codes are CARC/RARC codes such as
    # "CO-97"; reason_token is an optional vault token for remark text. With no
    # codes given, the codes already recorded are kept.
    def mark_denied!(reason_codes: [], reason_token: nil)
      codes = Array(reason_codes).map(&:to_s).reject(&:blank?)
      update!(
        status: "denied",
        denial_reason_codes: codes.presence || denial_reason_codes,
        denial_reason_token: reason_token || denial_reason_token
      )
    end

    # Records the staff override that releases a pending-Medicaid hold.
    # reason_token is a vault token for the reason, never free text.
    # overridden_at is Time.current, never a caller-supplied time.
    # Each call appends a staff_review Determination and keeps the prior ones.
    # Raises when this claim is not currently held, and records nothing.
    # A rolled-back write reloads this object so the hold stays in force.
    # The row lock is held while SubmissionOutcomeUnknown and the pending
    # hold are re-checked, before any write. confirm_submission_not_sent!
    # is required before another override while the marker is set.
    def override_medicaid_hold!(reason_token:, by_identifier:)
      require_medicaid_hold_override_args!(reason_token, by_identifier)
      refuse_unknown_submission_outcome!
      persist_medicaid_hold_override!(reason_token, by_identifier)
    end

    # Staff confirmed the clearinghouse did not accept the send whose
    # outcome was unknown. Clears the marker and appends a staff_review
    # Determination, the same audit shape as an override, with no free
    # text. The row lock is held while the marker is re-checked.
    # Another override is allowed only after this.
    def confirm_submission_not_sent!(by_identifier:)
      raise ArgumentError, "by_identifier is blank" if by_identifier.blank?

      persist_confirmed_not_sent!(by_identifier)
    end

    # A submit that spends a Medicaid hold override commits that spend
    # and submission_outcome_unknown_at before the clearinghouse call,
    # then sends in a second transaction. The marker is committed
    # first so a killed process, an aborted database transaction, or
    # a failed result save cannot restore the override or hide that
    # the outcome is unknown. Between those phases the marker blocks
    # any other submit or override of this claim. A submit with no
    # override in force stays one transaction: an adapter error rolls
    # back and nothing is marked.
    def submit!
      refuse_unknown_submission_outcome!
      prepare_for_clearinghouse_submit!
      if medicaid_hold_override_to_spend?
        submit_spending_medicaid_hold_override!
      else
        submit_without_override!
      end
    end

    # Patient-level lock shared with Medicaid AlternateResourceCheck
    # writes. Transaction-scoped, so each phase holds it until that
    # phase commits or rolls back. Phase B holds it across the
    # clearinghouse call. The integers are a hash of the claim's
    # tenant and patient; those tokens are not interpolated into
    # the statement or into errors.
    def self.lock_medicaid_patient_submission!(tenant_identifier, patient_identifier)
      key1, key2 = medicaid_patient_lock_keys(tenant_identifier, patient_identifier)
      # The inner call returns void. Selecting 1 keeps that type out of
      # the result so the adapter does not warn on an unknown OID, and
      # the patient token is not part of the statement.
      sql = sanitize_sql_array([
        "SELECT 1 FROM (SELECT pg_advisory_xact_lock(CAST(? AS integer), CAST(? AS integer))) AS locked",
        key1, key2
      ])
      with_connection { |db| db.select_value(sql) }
    end

    def self.medicaid_patient_lock_keys(tenant_identifier, patient_identifier)
      if tenant_identifier.blank? || patient_identifier.blank?
        raise ArgumentError, "Medicaid submission lock requires a tenant and a patient"
      end

      digest = Digest::SHA256.digest(
        medicaid_lock_material(tenant_identifier, patient_identifier)
      )
      [ digest.byteslice(0, 4).unpack1("l>"), digest.byteslice(4, 4).unpack1("l>") ]
    end
    private_class_method :medicaid_patient_lock_keys

    def self.medicaid_lock_material(tenant_identifier, patient_identifier)
      encoded = [ tenant_identifier, patient_identifier ].map { |value| "#{value.bytesize}:#{value}" }
      [ MEDICAID_SUBMISSION_LOCK_PREFIX, *encoded ].join("\0")
    end
    private_class_method :medicaid_lock_material

    def check_status!
      return unless claim_identifier
      result = Corvid.adapter.check_claim_status(claim_identifier)
      # Unknown claim: fail closed and leave every attribute unchanged.
      return nil if result.nil?

      attrs = { last_checked_at: Time.current }
      attrs[:status] = result[:status] if STATUSES.include?(result[:status])
      attrs[:rejection_reason_token] = result[:rejection_reason_token] if result[:rejection_reason_token]
      # A poll that reports no codes says nothing about a past denial, so it
      # must not erase the codes already recorded for it.
      denial_codes = Array(result[:denial_reason_codes]).map(&:to_s).reject(&:blank?)
      attrs[:denial_reason_codes] = denial_codes if denial_codes.any?
      attrs[:paid_amount] = result[:paid_amount] if result[:paid_amount]
      attrs[:adjustment_amount] = result[:adjustment_amount] if result[:adjustment_amount]
      attrs[:paid_date] = result[:paid_date] if result[:paid_date]
      save_status_poll!(attrs)
      result
    end

    # All four operands share a single row's currency, so Money
    # arithmetic is safe (the gem raises across mixed currencies, but
    # within one row that's impossible by construction).
    def total_adjustment
      zero = Money.new(0, currency_iso)
      (adjustment_amount || zero) + (patient_responsibility || zero)
    end

    def balance_due
      zero = Money.new(0, currency_iso)
      (billed_amount || zero) - (paid_amount || zero) - total_adjustment
    end

    private

    def stamp_rejection_and_denial_times
      self.rejected_at ||= Time.current if status == "rejected"
      self.denied_at ||= Time.current if status == "denied"
    end

    # PRC-linked claims: a plain save cannot enter "submitted" from any
    # stored status, and cannot leave an unsent row — draft, or error
    # without a claim_identifier — for a sent status. The link is the
    # resolved prc_referral_id or the one still stored on the row, so
    # unlinking in the same save does not step around the gate. submit!
    # and mark_submitted! are the gated writers. An error that already
    # has a claim_identifier was sent; check_status!, payment, or
    # remittance may move it, including back to "submitted". Moves
    # between sent statuses stay open whether or not submitted_at was
    # stamped. Creating a row already sent is a historical import and
    # is not validated here.
    def submission_status_requires_gate
      return if @submission_through_gate || status_poll_of_sent_claim?
      return unless guarded_status_transition?

      errors.add(:status, "must be submitted with submit! or mark_submitted!")
    end

    # A poll may record any valid status, including "submitted", once the
    # claim was actually sent. It does not write the sent markers, and a
    # plain save stays on the submission gate.
    def save_status_poll!(attributes)
      @recording_status_poll = true
      update!(attributes)
    ensure
      @recording_status_poll = false
    end

    def status_poll_of_sent_claim?
      @recording_status_poll && !unsent_status_in_database?
    end

    def guarded_status_transition?
      linked_prc_claim? && will_save_change_to_status? && submission_transition_blocked?
    end

    def submission_transition_blocked?
      status == "submitted" || unsent_to_sent_status?
    end

    def unsent_to_sent_status?
      unsent_status_in_database? && SENT_STATUSES.include?(status)
    end

    def unsent_status_in_database?
      return false unless UNSENT_STATUSES.include?(status_in_database)
      return false if sent_despite_error_status?

      true
    end

    # Adapter status "error" can still mean the claim was sent: a
    # claim_identifier was assigned. submitted_at by itself does not.
    # A time stamp without an identifier is not proof the claim was sent.
    def sent_despite_error_status?
      status_in_database == "error" && claim_identifier_in_database.present?
    end

    # An unsent linked claim may gain claim_identifier or submitted_at
    # only through save_through_submission_gate!. A plain save that writes
    # either marker is rejected, whether or not it also changes other
    # attributes. Editing referral_identifier can clear prc_referral_id
    # before validation; the stored link still counts. submit! and
    # mark_submitted! are the only writers.
    def unsent_linked_claim_cannot_gain_sent_markers
      return if @submission_through_gate
      return unless linked_unsent_claim? && sent_marker_changing?

      add_sent_marker_errors
    end

    def linked_unsent_claim?
      linked_prc_claim? && unsent_status_in_database?
    end

    # The resolved id is the link this save would store. The database id
    # is the link the row already has. An unlink leaves only the latter.
    def linked_prc_claim?
      prc_referral_id.present? || prc_referral_id_in_database.present?
    end

    # Attaching a referral to a claim that already carries sent markers
    # or a sent status would put a sent bill on whatever referral the
    # identifier names, including a draft. submit! and mark_submitted!
    # may link while they pass the gates. A plain save may not.
    def cannot_attach_ungated_sent_claim
      return if @submission_through_gate
      return unless attaching_prc_referral?
      return unless ungated_sent_claim?

      add_ungated_link_errors
    end

    def attaching_prc_referral?
      will_save_change_to_prc_referral_id? && prc_referral_id.present? &&
        prc_referral_id != prc_referral_id_in_database
    end

    def ungated_sent_claim?
      claim_identifier.present? || submitted_at.present? || SENT_STATUSES.include?(status)
    end

    def add_ungated_link_errors
      errors.add(:claim_identifier, SENT_MARKER_MESSAGE) if claim_identifier.present?
      errors.add(:submitted_at, SENT_MARKER_MESSAGE) if submitted_at.present?
      return unless SENT_STATUSES.include?(status)

      errors.add(:status, "must be submitted with submit! or mark_submitted!")
    end

    def sent_marker_changing?
      will_save_change_to_claim_identifier? || will_save_change_to_submitted_at?
    end

    def add_sent_marker_errors
      errors.add(:claim_identifier, SENT_MARKER_MESSAGE) if will_save_change_to_claim_identifier?
      errors.add(:submitted_at, SENT_MARKER_MESSAGE) if will_save_change_to_submitted_at?
    end

    def schedule_submission_provenance
      return unless @submission_through_gate
      return if prc_referral.blank?

      entities = AlternateResourceReverification.snapshot_entities(
        prc_referral.alternate_resource_checks.reload
      )
      tenant = Corvid::TenantContext.current_tenant_identifier
      # Same transaction as the save. Commit delivers once. Rollback drops
      # the callback, so a later plain save cannot publish this submission.
      self.class.current_transaction.after_commit do
        deliver_submission_provenance(entities, tenant)
      end
    end

    def deliver_submission_provenance(entities, tenant)
      return if prc_referral.blank?

      AlternateResourceReverification.record!(
        self,
        activity: "CREATE",
        entities: entities,
        tenant: tenant
      )
    end

    def save_through_submission_gate!(attributes)
      @submission_through_gate = true
      update!(attributes)
    ensure
      @submission_through_gate = false
    end

    # Recompute when the identifier, facility, or patient changes, and
    # when an unsent claim's link is still blank. An already-sent claim
    # with no link stays unlinked unless referral_identifier changes:
    # a blank prc_referral_id is not an edit. Stored claim_identifier,
    # stored submitted_at, or a stored sent status means already sent,
    # including submitted_at on an error row. Assigning prc_referral is
    # left in place for the ungated-sent guard. A new row still resolves,
    # and submit! / mark_submitted! link through the gate.
    def referral_link_inputs_changed?
      return false if referral_identifier.blank?
      return will_save_change_to_referral_identifier? if unlinked_claim_already_sent?

      prc_referral_id.blank? || referral_link_fields_changed?
    end

    def referral_link_fields_changed?
      will_save_change_to_referral_identifier? ||
        will_save_change_to_facility_identifier? ||
        will_save_change_to_patient_identifier?
    end

    def unlinked_claim_already_sent?
      prc_referral_id.blank? && sent_claim_stored?
    end

    # Distinct from the status-move rule, where submitted_at alone does
    # not make an error row sent. Here a stored submitted_at is enough
    # to leave the claim unlinked, because attaching it would fail the
    # ungated-sent guard.
    def sent_claim_stored?
      return false if new_record?

      claim_identifier_in_database.present? ||
        submitted_at_in_database.present? ||
        SENT_STATUSES.include?(status_in_database)
    end

    # Link this claim to the referral it bills, but only where that link is
    # unambiguous AND belongs to the same patient.
    #
    # Two separate ways to reach the wrong referral:
    #
    #   Ambiguity — PrcReferral scopes uniqueness to [tenant, facility], and
    #   PostgreSQL treats NULLs as distinct in a unique index, so several
    #   referrals can share a tenant and identifier while facility_identifier
    #   is NULL. Taking the first row back picks one arbitrarily.
    #
    #   The wrong patient — a single match on facility and identifier says
    #   nothing about whose care it authorized. Without this check, patient
    #   B's claim links to patient A's referral and #submit! then accepts A's
    #   authorization for B's bill.
    #
    # A claim that resolves to neither stays unlinked, and #submit! decides
    # what that means.
    def resolve_prc_referral_from_identifier
      candidates = Corvid::PrcReferral
        .includes(:case)
        .where(facility_identifier: facility_identifier, referral_identifier: referral_identifier)
        .limit(2)
        .to_a

      self.prc_referral =
        if candidates.size == 1 && candidates.first.case&.patient_identifier == patient_identifier
          candidates.first
        end
    end

    # A linked referral is re-verified for service_date before the claim is
    # sent. No linked PRC referral is ordinary billing and skips this gate.
    # A nil service date fails closed.
    def enforce_alternate_resources_current!
      referral = referral_for_alternate_resource_gate
      return if referral.nil?
      return if alternate_resources_current?(referral)

      raise AlternateResourcesNotCurrent
    end

    def referral_for_alternate_resource_gate
      resolve_prc_referral_from_identifier if prc_referral.blank? && referral_identifier.present?
      prc_referral
    end

    # Re-verify first, then decide. A stale row that comes back current and
    # exhausted is a determination this submission can rely on. An unreadable
    # answer leaves the row unchanged and the claim is refused.
    def alternate_resources_current?(referral)
      return false if service_date.nil?
      return false unless AlternateResourceReverification.reverify_stale!(
        referral, date_of_service: service_date, as_of: Time.current
      )

      exhausted_for_claim?(referral)
    end

    def exhausted_for_claim?(referral)
      AlternateResourceCheck.all_exhausted?(referral, date_of_service: service_date, as_of: Time.current)
    end

    # A claim that bills a PRC referral may only be submitted once that
    # referral is authorized.
    #
    # referral_identifier is a loose external reference: plenty of claims carry
    # a payer's or provider's referral number with no PrcReferral behind it
    # (see features/billing/claims_submission.feature), and those are ordinary
    # billing, not PRC billing. So an identifier matching nothing is allowed
    # through — the claim is simply not a PRC claim.
    #
    # What is NOT allowed through is an identifier that matches PRC referrals
    # ambiguously. There a PRC referral demonstrably exists under that
    # identifier and we cannot tell which, so we cannot establish that the one
    # being billed was authorized.
    #
    # Resolution happens here rather than relying on the association, because
    # the resolver runs on save: a claim can reach #submit! carrying an
    # identifier whose prc_referral_id is still NULL, and returning early on a
    # blank association would skip exactly the rows the gate exists for.
    def enforce_referral_authorization_gate!
      resolve_prc_referral_from_identifier if prc_referral.blank? && referral_identifier.present?

      if prc_referral.blank?
        raise ReferralNotAuthorized,
          "Claim naming referral #{referral_identifier} cannot be submitted: " \
          "a PRC referral exists under that identifier at this facility but it " \
          "is not this patient's, or several share it, so the authorization " \
          "behind this bill cannot be established" if conflicting_referral_match?

        return
      end

      # Re-read before deciding. The association may have been loaded earlier
      # in this object's life, and authorizing care is exactly the kind of
      # thing that happens between loading a claim and submitting it.
      current = prc_referral.reload
      return if current.status == "authorized"

      raise ReferralNotAuthorized,
        "Claim for referral #{current.referral_identifier} cannot be submitted: " \
        "the referral is #{current.status}, not authorized"
    end

    # True when PRC referrals exist under this identifier at this facility but
    # none of them is this patient's — either several match (we cannot tell
    # which) or the only match authorized someone else's care. Both mean the
    # claim names a referral corvid knows and we cannot establish that THIS
    # bill was authorized, which is different from an identifier corvid has
    # never seen.
    def conflicting_referral_match?
      return false if referral_identifier.blank?

      Corvid::PrcReferral
        .where(facility_identifier: facility_identifier, referral_identifier: referral_identifier)
        .limit(1).exists?
    end

    def require_medicaid_hold_override_args!(reason_token, by_identifier)
      raise ArgumentError, "reason_token is blank" if reason_token.blank?
      raise ArgumentError, "by_identifier is blank" if by_identifier.blank?
    end

    def require_pending_medicaid_hold!
      return if pending_medicaid_hold_reason

      raise ArgumentError, "no pending Medicaid hold applies"
    end

    # The Determination and the three columns commit together. The row
    # lock is held while the marker and the pending hold are re-checked,
    # so a marker committed by an in-flight submit cannot be overwritten.
    # If the audit row raises, reload so this object does not keep a
    # rolled-back override that would release the next submit!.
    def persist_medicaid_hold_override!(reason_token, by_identifier)
      committed = false
      transaction do
        lock_submission_row!
        refuse_unknown_submission_outcome!
        require_pending_medicaid_hold!
        write_medicaid_hold_override!(reason_token, by_identifier)
        record_medicaid_hold_override!(reason_token, by_identifier)
        committed = true
      end
    ensure
      @writing_medicaid_hold_override = false
      reload if persisted? && !committed
    end

    def write_medicaid_hold_override!(reason_token, by_identifier)
      @writing_medicaid_hold_override = true
      update!(
        medicaid_hold_override_reason_token: reason_token,
        medicaid_hold_override_by_identifier: by_identifier,
        medicaid_hold_overridden_at: Time.current
      )
    end

    def record_medicaid_hold_override!(reason_token, by_identifier)
      record_staff_review_determination!(by_identifier: by_identifier, reasons_token: reason_token)
    end

    # Same audit row as an override: staff_review, no free text, no PHI.
    # reasons_token is a vault token when the caller has one.
    def record_staff_review_determination!(by_identifier:, reasons_token: nil)
      Determination.create!(
        determinable: self,
        tenant_identifier: tenant_identifier,
        facility_identifier: facility_identifier,
        decision_method: "staff_review",
        outcome: "approved",
        reasons_token: reasons_token,
        determined_by_identifier: by_identifier
      )
    end

    def persist_confirmed_not_sent!(by_identifier)
      committed = false
      transaction do
        lock_submission_row!
        require_unknown_submission_outcome!
        clear_submission_outcome_unknown!
        record_staff_review_determination!(by_identifier: by_identifier)
        committed = true
      end
    ensure
      reload if persisted? && !committed
    end

    def never_submitted_claim_stays_unsubmitted
      return if @recording_claim_submission
      return unless never_submitted_entering_submission?

      errors.add(:status, "can only become submitted, accepted, or paid through submit! or mark_submitted!")
    end

    # claim_identifier and submitted_at are how a later save tells a
    # sent claim from one that never left. While the stored status is
    # unsent, a plain save must not write either onto a never-sent row,
    # or a held draft can store an identifier and then walk into a sent
    # status. A row already stored as submitted, accepted, or paid may
    # record claim_identifier through a plain save. Inserts may still
    # carry them. submit! and mark_submitted! set the recording flag.
    def never_sent_claim_markers_only_through_submission
      return if @recording_claim_submission
      return unless persisted? && never_sent_in_database?
      return if sent_status?(status_in_database)

      refuse_plain_sent_marker(:claim_identifier) if will_save_change_to_claim_identifier?
      refuse_plain_sent_marker(:submitted_at) if will_save_change_to_submitted_at?
    end

    def refuse_plain_sent_marker(attribute)
      errors.add(attribute, "can only be recorded through submit! or mark_submitted!")
    end

    # submitted_at_in_database and claim_identifier_in_database are the
    # persisted signals that submit! or mark_submitted! sent this claim.
    # Values assigned on this save do not count. The stored status does
    # not count either: rejected, denied, and appealed are not a send.
    # A row inserted already submitted, accepted, or paid may still move
    # among those statuses. Once it leaves them, preserve_prior_sent_status
    # records submitted_at so that return is not treated as a first send.
    def never_submitted_entering_submission?
      persisted? && never_sent_in_database? && entering_sent_status?
    end

    def never_sent_in_database?
      submitted_at_in_database.nil? && claim_identifier_in_database.blank?
    end

    def entering_sent_status?
      sent_status?(status) && !sent_status?(status_in_database)
    end

    def sent_status?(value)
      PAYABLE_SENT_STATUSES.include?(value)
    end

    # A row created already submitted, accepted, or paid has entered the
    # submission lifecycle even when the insert left submitted_at nil.
    # Record that before the status moves to rejected, denied, or
    # appealed, or a later plain save could not be told from a draft
    # that was never sent.
    def leaving_unrecorded_sent_status?
      will_save_change_to_status? &&
        sent_status?(status_in_database) &&
        !sent_status?(status) &&
        submitted_at.nil? &&
        claim_identifier.blank?
    end

    def preserve_prior_sent_status
      self.submitted_at = created_at || Time.current
    end

    def medicaid_hold_override_not_assigned_directly
      return if @writing_medicaid_hold_override
      return unless medicaid_hold_override_changed?

      errors.add(:medicaid_hold_override_reason_token, "can only be changed through override_medicaid_hold!")
    end

    def submission_outcome_unknown_not_assigned_directly
      return if @writing_submission_outcome_unknown
      return unless will_save_change_to_submission_outcome_unknown_at?

      errors.add(:submission_outcome_unknown_at, "can only be changed through claim submission")
    end

    def medicaid_hold_override_all_or_none
      values = MEDICAID_HOLD_OVERRIDE_COLUMNS.map { |name| public_send(name) }
      return if values.all?(&:nil?) || values.all?(&:present?)

      errors.add(:medicaid_hold_override_reason_token, "must be recorded with the staff identifier and time")
    end

    def medicaid_hold_override_changed?
      MEDICAID_HOLD_OVERRIDE_COLUMNS.any? { |name| will_save_change_to_attribute?(name) }
    end

    # A service date, patient, or referral link change makes the recorded
    # override describe a different bill. Drop it so the next submit! is
    # held again. Skipped while an internal writer is changing the columns.
    def clear_medicaid_hold_override_when_basis_changes
      return if @writing_medicaid_hold_override
      return unless persisted? && hold_basis_changed? && medicaid_hold_override_recorded?

      assign_attributes(cleared_medicaid_hold_override_attributes)
    end

    def hold_basis_changed?
      will_save_change_to_service_date? ||
        will_save_change_to_patient_identifier? ||
        will_save_change_to_referral_identifier? ||
        will_save_change_to_prc_referral_id?
    end

    def medicaid_hold_override_recorded?
      MEDICAID_HOLD_OVERRIDE_COLUMNS.any? { |name| public_send(name).present? }
    end

    # PRC is payer of last resort. Hold while any pending Medicaid
    # application for this patient, in the claim's own tenant, covers
    # the service date or that window cannot be determined. The active
    # TenantContext is not the scope: a held claim must not be sent
    # under another tenant. The claim's own referral is not special.
    # The check does not record an Indian exemption, so resolution
    # passes "unknown".
    #
    # An override releases the hold only from the persisted columns.
    # Unsaved assignments are ignored. Unsaved changes to the bill's
    # basis refuse this call before the clearinghouse adapter runs,
    # because the in-memory bill and the row under the lock would
    # disagree. A Case, PrcReferral, or Medicaid check for this patient
    # created or updated after medicaid_hold_overridden_at ends the
    # release. Those reads are filtered by this claim's tenant_identifier.
    def enforce_pending_medicaid_hold!
      refuse_unsaved_medicaid_hold_override!
      return if active_persisted_medicaid_hold_override?

      raise_for_pending_medicaid_hold!
    end

    # Called before the row lock. lock! refuses a dirty record, and a
    # reload would hide the unsaved basis the caller asked us to refuse.
    # An unset tenant context refuses here, before any hold lookup, so
    # the claim is not evaluated against some other tenant and sent.
    def prepare_medicaid_hold_submission!
      require_submission_tenant_context!
      refuse_unsaved_hold_basis_changes!
      refuse_unsaved_medicaid_hold_override!
      refuse_unsaved_claim_changes!
    end

    def prepare_for_clearinghouse_submit!
      prepare_medicaid_hold_submission!
      enforce_referral_authorization_gate!
      enforce_alternate_resources_current!
      discard_resolved_referral_link!
      refuse_unsaved_claim_changes!
    end

    def require_submission_tenant_context!
      return if Corvid::TenantContext.current_tenant_identifier.present?

      raise Corvid::MissingTenantContextError, "current_tenant_identifier not set"
    end

    def refuse_unsaved_claim_changes!
      return unless persisted? && has_changes_to_save?

      raise UnsavedChanges, "unsaved changes must be saved before submission"
    end

    # The advisory lock and the row lock share one transaction, so a
    # Medicaid write for this patient waits until this phase commits.
    # Both phases of an override submit take this lock. Between them
    # the in-flight marker blocks any other submit or override.
    def with_medicaid_submission_lock
      transaction do
        lock_patient_medicaid_submission!
        with_lock { yield }
      end
    end

    def lock_submission_row!
      lock_patient_medicaid_submission!
      lock!
    end

    def lock_patient_medicaid_submission!
      self.class.lock_medicaid_patient_submission!(tenant_identifier, patient_identifier)
    end

    # The basis on the locked row is the only basis we can hold against.
    # An unsaved patient, service date, or referral link makes the window
    # undetermined. Do not evaluate either version, and do not consume
    # an override.
    def refuse_unsaved_hold_basis_changes!
      return unless persisted? && hold_basis_changed?

      raise HeldForPendingMedicaid, HeldForPendingMedicaid::WINDOW_UNDETERMINED
    end

    # The authorization gate links a blank prc_referral_id in memory.
    # That is not a caller edit. lock! refuses a dirty record, so drop
    # the link before taking the lock. The gate has already run.
    def discard_resolved_referral_link!
      return unless persisted?
      return unless changed == [ "prc_referral_id" ]

      reload
    end

    # The marker is a column on this row. Read it without the active
    # tenant scope so another tenant's context cannot hide it.
    def persisted_submission_outcome_unknown_at
      return unless persisted?
      return unless has_attribute?(:submission_outcome_unknown_at)

      self.class.unscoped.where(id: id).pick(:submission_outcome_unknown_at)
    end

    def submission_outcome_unknown?
      persisted_submission_outcome_unknown_at.present?
    end

    def refuse_unknown_submission_outcome!
      return unless submission_outcome_unknown?

      raise SubmissionOutcomeUnknown
    end

    def require_unknown_submission_outcome!
      return if submission_outcome_unknown?

      raise ArgumentError, "submission outcome is not unknown"
    end

    def clear_submission_outcome_unknown!
      write_submission_outcome_unknown!(nil)
    end

    def write_submission_outcome_unknown!(timestamp)
      @writing_submission_outcome_unknown = true
      update!(submission_outcome_unknown_at: timestamp)
    ensure
      @writing_submission_outcome_unknown = false
    end

    # Override submits must be top-level. Any open transaction,
    # joinable or not, is refused before locks, the spend, or the
    # adapter. The caller could roll that transaction back after the
    # clearinghouse had accepted the claim.
    def submit_spending_medicaid_hold_override!
      refuse_override_submit_inside_open_transaction!
      return submit_without_override! unless commit_in_flight_override_spend!

      # Phase A has committed the spend and the in-flight marker.
      # Until phase B commits, that marker blocks any other submit
      # or override of this claim. Phase B rolls back alone.
      submit_in_flight_claim!
    end

    def refuse_override_submit_inside_open_transaction!
      raise OverrideRequiresTopLevelSubmit if caller_transaction_open?
    end

    def caller_transaction_open?
      self.class.connection.transaction_open?
    end

    def medicaid_hold_override_to_spend?
      return false if complete_persisted_override_at.nil?

      active_persisted_medicaid_hold_override? || pending_medicaid_hold_reason.nil?
    end

    # Phase A. The marker is committed before the send so a crash
    # during the adapter call, or a rollback of phase B, leaves the
    # override spent and the outcome unknown.
    def commit_in_flight_override_spend!
      with_medicaid_submission_lock { mark_in_flight_override_spend! }
    end

    def mark_in_flight_override_spend!
      refuse_unknown_submission_outcome!
      enforce_pending_medicaid_hold!
      return false unless complete_persisted_override_at

      write_in_flight_override_spend!
      true
    end

    def write_in_flight_override_spend!
      @writing_medicaid_hold_override = true
      @writing_submission_outcome_unknown = true
      update!(in_flight_override_spend_attributes)
    ensure
      @writing_medicaid_hold_override = false
      @writing_submission_outcome_unknown = false
    end

    def in_flight_override_spend_attributes
      cleared_medicaid_hold_override_attributes.merge(
        submission_outcome_unknown_at: Time.current
      )
    end

    # Phase B. A new transaction, the same patient advisory lock, and
    # the row lock. The accepted result and the cleared marker commit
    # in one save. Any exception rolls this phase back only and is
    # re-raised as itself. The same-connection clear before the
    # adapter is uncommitted, so other transactions still see the marker.
    def submit_in_flight_claim!
      with_medicaid_submission_lock { send_in_flight_claim! }
    end

    def send_in_flight_claim!
      clear_submission_outcome_unknown!
      result = Corvid.adapter.submit_claim(to_claim_data)
      record_accepted_submission!(result)
      result
    end

    def submit_without_override!
      with_medicaid_submission_lock { send_claim_without_override! }
    end

    def send_claim_without_override!
      refuse_unknown_submission_outcome!
      enforce_pending_medicaid_hold!
      result = Corvid.adapter.submit_claim(to_claim_data)
      record_accepted_submission!(result)
      result
    end

    def record_accepted_submission!(result)
      record_claim_submission!(
        claim_identifier: result[:claim_identifier],
        status: clearinghouse_submission_status(result[:status])
      )
    end

    def refuse_unsaved_medicaid_hold_override!
      return unless medicaid_hold_override_changed?

      raise_for_pending_medicaid_hold!
      raise ArgumentError, "medicaid hold override has unsaved changes"
    end

    def raise_for_pending_medicaid_hold!
      reason = pending_medicaid_hold_reason
      return if reason.nil?

      raise HeldForPendingMedicaid, reason
    end

    # Fresh read, not the in-memory attributes. A rolled-back
    # override_medicaid_hold! can leave those looking saved.
    def active_persisted_medicaid_hold_override?
      overridden_at = complete_persisted_override_at
      return false if overridden_at.nil?
      return false if patient_records_changed_since?(overridden_at)

      true
    end

    def complete_persisted_override_at
      token, actor, overridden_at = persisted_medicaid_hold_override
      return unless token.present? && actor.present? && overridden_at.present?

      overridden_at
    end

    def persisted_medicaid_hold_override
      return unless persisted?

      self.class.where(id: id).pick(*MEDICAID_HOLD_OVERRIDE_COLUMNS)
    end

    # Cases and referrals are filtered by this claim's tenant_identifier,
    # not by TenantContext. Medicaid checks have no tenant column; they
    # are reached through those referrals, so another tenant's
    # application is not a change.
    def patient_records_changed_since?(overridden_at)
      return false if patient_identifier.blank?

      [ patient_cases, patient_referrals, patient_medicaid_checks ].any? do |relation|
        changed_since?(relation, overridden_at)
      end
    end

    def changed_since?(relation, overridden_at)
      table = relation.arel_table
      relation.where(
        table[:updated_at].gt(overridden_at).or(table[:created_at].gt(overridden_at))
      ).exists?
    end

    def patient_cases
      return Case.unscoped.none if patient_identifier.blank?

      Case.unscoped.where(
        tenant_identifier: tenant_identifier,
        patient_identifier: patient_identifier
      )
    end

    def patient_referrals
      PrcReferral.unscoped.where(
        tenant_identifier: tenant_identifier,
        case_id: patient_case_ids
      )
    end

    def clearinghouse_submission_status(status)
      status == "accepted" ? "submitted" : status
    end

    # Recording an identifier for a send whose outcome was unknown is
    # reconciliation, not a new send, so the pending Medicaid hold does
    # not apply. The marker is cleared with the identifier.
    def record_marked_submission!(claim_identifier)
      enforce_pending_medicaid_hold! unless submission_outcome_unknown?
      record_claim_submission!(claim_identifier:, status: "submitted")
    end

    # Clears the override through the internal writer so the direct-write
    # validation does not reject the submission that consumed it. The
    # Determination audit row is left in place. Also clears
    # submission_outcome_unknown_at, which mark_submitted! uses when
    # staff confirm the unknown send did go out. The save goes through
    # the submission gate, so the sent-marker guards accept it and the
    # alternate-resource provenance is published on commit.
    def record_claim_submission!(claim_identifier:, status:)
      @recording_claim_submission = true
      @writing_medicaid_hold_override = true
      @writing_submission_outcome_unknown = true
      save_through_submission_gate!(submission_attributes(claim_identifier, status))
    ensure
      @recording_claim_submission = false
      @writing_medicaid_hold_override = false
      @writing_submission_outcome_unknown = false
    end

    def submission_attributes(claim_identifier, status)
      {
        claim_identifier: claim_identifier,
        status: status,
        submitted_at: Time.current,
        submission_outcome_unknown_at: nil
      }.merge(cleared_medicaid_hold_override_attributes)
    end

    def cleared_medicaid_hold_override_attributes
      {
        medicaid_hold_override_reason_token: nil,
        medicaid_hold_override_by_identifier: nil,
        medicaid_hold_overridden_at: nil
      }
    end

    def pending_medicaid_hold_reason
      reasons = pending_medicaid_checks.filter_map { |check| medicaid_hold_reason(check) }
      return if reasons.empty?
      return HeldForPendingMedicaid::INSIDE_RETROACTIVE_WINDOW if reasons.include?(inside_window_reason)

      HeldForPendingMedicaid::WINDOW_UNDETERMINED
    end

    def inside_window_reason
      HeldForPendingMedicaid::INSIDE_RETROACTIVE_WINDOW
    end

    # Medicaid rows for this patient that can still cover the service.
    # The referral ids come from the claim's tenant, not the active one,
    # so another tenant's context cannot hide a pending application.
    def pending_medicaid_checks
      patient_medicaid_checks
        .where.not(status: MEDICAID_APPLICATION_ENDED_STATUSES)
        .where(
          "status = ? OR application_date IS NOT NULL",
          "pending_enrollment"
        )
    end

    def patient_medicaid_checks
      return AlternateResourceCheck.unscoped.none if patient_identifier.blank?

      AlternateResourceCheck.unscoped.where(
        prc_referral_id: patient_referral_ids,
        resource_type: "medicaid"
      )
    end

    def patient_referral_ids
      patient_referrals.select(:id)
    end

    def patient_case_ids
      patient_cases.select(:id)
    end

    # A future application date is not a window. Missing service date,
    # an unresolvable group, or a window that is not a determined
    # non-cover all fail closed.
    def medicaid_hold_reason(check)
      return undetermined_window_reason if service_date.nil? || future_application_date?(check)

      rule_set = medicaid_rule_set_for(check)
      return undetermined_window_reason unless rule_set

      coverage_hold_reason(check, rule_set)
    end

    def undetermined_window_reason
      HeldForPendingMedicaid::WINDOW_UNDETERMINED
    end

    def future_application_date?(check)
      check.future_application_date?
    end

    def coverage_hold_reason(check, rule_set)
      case RetroactiveCoverageWindow.covers?(
        date_of_service: service_date,
        application_date: check.application_date,
        rule_set:
      )
      when true then inside_window_reason
      when nil then undetermined_window_reason
      end
    end

    def medicaid_rule_set_for(check)
      return unless medicaid_inputs_resolvable?(check)

      MedicaidRuleSetResolver.resolve(
        eligibility_group: check.eligibility_group,
        state: check.medicaid_state_code,
        indian_exemption: "unknown"
      )
    end

    def medicaid_inputs_resolvable?(check)
      group = check.eligibility_group
      state = check.medicaid_state_code
      AlternateResourceCheck::ELIGIBILITY_GROUPS.include?(group) &&
        state.is_a?(String) &&
        state.match?(/\A[A-Z]{2}\z/)
    end

    def to_claim_data
      {
        patient_identifier: patient_identifier,
        referral_identifier: referral_identifier,
        claim_type: claim_type,
        billed_amount: billed_amount,
        payer_identifier: payer_identifier,
        service_date: service_date,
        provider_identifier: provider_identifier
      }
    end
  end
end
