# frozen_string_literal: true

module Corvid
  # Tracks 837P/I/D claims through lifecycle from draft to paid.
  # Ported from the predecessor app. Uses adapter pattern for clearinghouse
  # communication — Clearinghouse is one implementation (in lakeraven-private).
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

    # The referral this claim bills, where there is one. Optional: claims
    # billed outside the referral workflow, and legacy rows the backfill could
    # not match unambiguously, carry no reference.
    belongs_to :prc_referral, class_name: "Corvid::PrcReferral", optional: true

    validates :patient_identifier, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :claim_type, inclusion: { in: CLAIM_TYPES }
    validate :never_submitted_claim_stays_unsubmitted
    validate :medicaid_hold_override_not_assigned_directly
    validate :medicaid_hold_override_all_or_none

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

    # A plain save cannot move a never-submitted claim into the
    # submission lifecycle. error counts: a draft may stop there, and
    # the next save still cannot submit it. Creating a row that is
    # already submitted stays allowed. A row that already has
    # submitted_at, or whose status is already past draft and error,
    # can still change status.
    DRAFT_SUBMISSION_STATUSES = %w[submitted accepted paid].freeze
    private_constant :DRAFT_SUBMISSION_STATUSES
    NEVER_SUBMITTED_STATUSES = %w[draft error].freeze
    private_constant :NEVER_SUBMITTED_STATUSES

    # The link is derived from referral_identifier + facility_identifier +
    # patient_identifier, so it is recomputed whenever any of those change.
    # Resolving only a blank link left an edited claim pointing at the
    # referral it used to name: #submit! checked that one's authorization
    # while #to_claim_data sent the new identifier to the payer.
    before_validation :resolve_prc_referral_from_identifier,
      if: :referral_link_inputs_changed?

    # Every path into rejected or denied (submit!, check_status!, the mark_*
    # helpers, remittance processing) records when it first happened, so the
    # KPIs above still count the claim after its status moves on.
    before_save :stamp_rejection_and_denial_times, if: :will_save_change_to_status?
    # After validation, so this clear is not a direct write of the
    # override columns. A caller who assigns those columns still fails.
    before_save :clear_medicaid_hold_override_when_basis_changes

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
      prepare_medicaid_hold_submission!
      with_lock do
        enforce_pending_medicaid_hold!
        record_claim_submission!(claim_identifier:, status: "submitted")
      end
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
    def override_medicaid_hold!(reason_token:, by_identifier:)
      require_medicaid_hold_override_args!(reason_token, by_identifier)
      require_pending_medicaid_hold!
      persist_medicaid_hold_override!(reason_token, by_identifier)
    end

    def submit!
      prepare_medicaid_hold_submission!
      enforce_referral_authorization_gate!
      discard_resolved_referral_link!
      with_lock { submit_locked! }
    end

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
      update!(attrs)
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

    # Link this claim to the referral it bills, but only where that link is
    # unambiguous. PrcReferral scopes uniqueness to [tenant, facility], and
    # PostgreSQL treats NULLs as distinct in a unique index, so several
    # referrals can share a tenant and identifier while facility_identifier is
    # NULL. Taking the first row back would attach a claim to an arbitrary
    # one — another patient's referral. Where more than one matches, the claim
    # stays unlinked and #submit! refuses it rather than billing against a
    # referral nobody chose.
    def referral_link_inputs_changed?
      return false if referral_identifier.blank?

      prc_referral_id.blank? ||
        will_save_change_to_referral_identifier? ||
        will_save_change_to_facility_identifier? ||
        will_save_change_to_patient_identifier?
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

    # The Determination and the three columns commit together. If the
    # audit row raises, reload so this object does not keep a rolled-back
    # override that would release the next submit!.
    def persist_medicaid_hold_override!(reason_token, by_identifier)
      committed = false
      transaction do
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
      Determination.create!(
        determinable: self,
        tenant_identifier: tenant_identifier,
        facility_identifier: facility_identifier,
        decision_method: "staff_review",
        outcome: "approved",
        reasons_token: reason_token,
        determined_by_identifier: by_identifier
      )
    end

    def never_submitted_claim_stays_unsubmitted
      return if @recording_claim_submission
      return unless never_submitted_entering_submission?

      errors.add(:status, "can only become submitted, accepted, or paid through submit! or mark_submitted!")
    end

    # submitted_at_in_database is the persisted signal that this claim
    # has been sent. Setting submitted_at on the same save does not
    # count. Fixtures created already submitted, accepted, or paid have
    # a status outside NEVER_SUBMITTED_STATUSES, so later status edits
    # stay valid even when that timestamp was left nil.
    def never_submitted_entering_submission?
      persisted? &&
        submitted_at_in_database.nil? &&
        NEVER_SUBMITTED_STATUSES.include?(status_in_database) &&
        DRAFT_SUBMISSION_STATUSES.include?(status)
    end

    def medicaid_hold_override_not_assigned_directly
      return if @writing_medicaid_hold_override
      return unless medicaid_hold_override_changed?

      errors.add(:medicaid_hold_override_reason_token, "can only be changed through override_medicaid_hold!")
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
    # application for this patient, in this tenant, covers the service
    # date or that window cannot be determined. The claim's own referral
    # is not special. The check does not record an Indian exemption, so
    # resolution passes "unknown".
    #
    # An override releases the hold only from the persisted columns.
    # Unsaved assignments are ignored. Unsaved changes to the bill's
    # basis refuse this call before the clearinghouse adapter runs,
    # because the in-memory bill and the row under the lock would
    # disagree. A Case, PrcReferral, or Medicaid check for this patient
    # created or updated after medicaid_hold_overridden_at ends the
    # release. Those reads stay on the tenant-scoped models (ADR 0002).
    def enforce_pending_medicaid_hold!
      refuse_unsaved_medicaid_hold_override!
      return if active_persisted_medicaid_hold_override?

      raise_for_pending_medicaid_hold!
    end

    # Called before the row lock. lock! refuses a dirty record, and a
    # reload would hide the unsaved basis the caller asked us to refuse.
    def prepare_medicaid_hold_submission!
      refuse_unsaved_hold_basis_changes!
      refuse_unsaved_medicaid_hold_override!
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

    # The row lock covers the hold check, the adapter call, and the
    # status update. The override is cleared before the adapter so a
    # second submit! on this connection, while the adapter is in flight,
    # re-reads a row whose override is already spent and is held.
    # A later submit! on another connection blocks on the lock, then
    # re-reads the committed row. A failed adapter rolls the clear back
    # with the rest of the transaction.
    def submit_locked!
      enforce_pending_medicaid_hold!
      release_persisted_medicaid_hold_override!
      result = Corvid.adapter.submit_claim(to_claim_data)
      record_claim_submission!(
        claim_identifier: result[:claim_identifier],
        status: clearinghouse_submission_status(result[:status])
      )
      result
    end

    def release_persisted_medicaid_hold_override!
      return if complete_persisted_override_at.nil?

      @writing_medicaid_hold_override = true
      update!(cleared_medicaid_hold_override_attributes)
    ensure
      @writing_medicaid_hold_override = false
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

    # Cases and referrals are tenant-scoped (ADR 0002). Medicaid checks
    # have no tenant column; they are reached through those referrals,
    # so another tenant's application is not a change.
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
      return Case.none if patient_identifier.blank?

      Case.where(patient_identifier: patient_identifier)
    end

    def patient_referrals
      PrcReferral.where(case_id: patient_case_ids)
    end

    def clearinghouse_submission_status(status)
      status == "accepted" ? "submitted" : status
    end

    # Clears the override through the internal writer so the direct-write
    # validation does not reject the submission that consumed it. The
    # Determination audit row is left in place.
    def record_claim_submission!(claim_identifier:, status:)
      @recording_claim_submission = true
      @writing_medicaid_hold_override = true
      update!(submission_attributes(claim_identifier, status))
    ensure
      @recording_claim_submission = false
      @writing_medicaid_hold_override = false
    end

    def submission_attributes(claim_identifier, status)
      {
        claim_identifier: claim_identifier,
        status: status,
        submitted_at: Time.current
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
    # Case and PrcReferral are tenant-scoped (ADR 0002), so another
    # tenant's application is invisible here.
    def pending_medicaid_checks
      patient_medicaid_checks
        .where.not(status: MEDICAID_APPLICATION_ENDED_STATUSES)
        .where(
          "status = ? OR application_date IS NOT NULL",
          "pending_enrollment"
        )
    end

    def patient_medicaid_checks
      return AlternateResourceCheck.none if patient_identifier.blank?

      AlternateResourceCheck.where(
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
