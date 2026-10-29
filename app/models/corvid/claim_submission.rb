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
    # An already-sent unlinked claim is not resolved on a plain save when
    # referral_identifier is unchanged. For that skip, stored claim_identifier,
    # stored submitted_at, or a stored sent status counts, including
    # submitted_at on an error row, so a referral entered later does not block
    # check_status!, payment, remittance, or a plain edit. Changing
    # referral_identifier still resolves and is refused. Assigning
    # prc_referral is refused the same way. Unsent claims and new rows still
    # resolve a blank link. submit! and mark_submitted! are the only paths
    # that write those markers or enter "submitted" from an unsent row.
    # Their gates read an unambiguous same-patient referral when the stored
    # link is blank, without assigning it, and the gated save links it.
    # check_status! may record "submitted" on a claim that was
    # already sent. Later moves among sent statuses, including an error
    # that was actually sent, do not depend on submitted_at. A row created
    # already sent is a historical import and is left unstamped.
    UNSENT_STATUSES = %w[draft error].freeze
    SENT_STATUSES = %w[submitted accepted rejected paid denied appealed].freeze
    SENT_MARKER_MESSAGE = "must be set with submit! or mark_submitted!"

    # Raised by #submit! and #mark_submitted! when this claim bills a PRC
    # referral that has not been authorized, or names one that cannot be
    # tied to this patient. PRC authorizes before care is purchased, so
    # billing an unauthorized referral bills care the programme never
    # agreed to buy.
    class ReferralNotAuthorized < StandardError; end

    # Raised by #submit! and #mark_submitted! when this claim bills a PRC
    # referral whose delivered care has not been recorded. No report means
    # awaiting_report. A not_delivered report is not billable (corvid#599).
    class FulfilmentNotRecorded < StandardError; end

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
      # Same order as submit!: an unauthorized referral is refused first,
      # then unrecorded fulfilment, then any payer re-verification.
      enforce_referral_authorization_gate!
      enforce_referral_fulfilment_gate!
      enforce_alternate_resources_current!
      save_through_submission_gate!(
        claim_identifier: claim_identifier,
        status: "submitted",
        submitted_at: Time.current
      )
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

    def submit!
      enforce_referral_authorization_gate!
      # Fulfilment is decided before payer re-verification and before
      # the clearinghouse is touched.
      enforce_referral_fulfilment_gate!
      enforce_alternate_resources_current!
      result = Corvid.adapter.submit_claim(to_claim_data)
      save_through_submission_gate!(
        claim_identifier: result[:claim_identifier],
        status: result[:status] == "accepted" ? "submitted" : result[:status],
        submitted_at: Time.current
      )
      result
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
    # when a link is still blank. An already-sent claim with no link stays
    # unlinked on a plain save unless referral_identifier changes: a blank
    # prc_referral_id is not an edit. A save through the submission gate
    # resolves that blank link, and the ungated-sent guard allows the
    # attach. Stored claim_identifier, stored submitted_at, or a stored
    # sent status means already sent, including submitted_at on an error
    # row. Assigning prc_referral is left in place for that guard. A new
    # row still resolves.
    def referral_link_inputs_changed?
      return false if referral_identifier.blank?
      return will_save_change_to_referral_identifier? if unlinked_claim_already_sent? && !@submission_through_gate

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
      self.prc_referral = unambiguous_patient_referral
    end

    def unambiguous_patient_referral
      return if referral_identifier.blank?

      candidates = Corvid::PrcReferral
        .includes(:case)
        .where(facility_identifier: facility_identifier, referral_identifier: referral_identifier)
        .limit(2)
        .to_a
      candidate = candidates.first
      return if candidates.size != 1 || candidate.case&.patient_identifier != patient_identifier

      candidate
    end

    # A PRC referral is billable only when an external report names
    # delivered care. The referral is referral_for_submission_gates: the
    # one this save will link, read from the current identifier without
    # assigning the association. No resolvable referral is ordinary
    # billing and is left alone. A dirty referral_identifier must not be
    # judged against the referral this claim used to name. Called before
    # any clearinghouse call, so a refusal never submits and never changes
    # the claim. The message names the referral identifier and the
    # fulfilment status only (ADR 0003).
    def enforce_referral_fulfilment_gate!
      referral = referral_for_submission_gates
      return if referral.blank?

      current = referral.reload
      return if Corvid::ReferralFulfilment.billable_for_delivered_care?(current)

      raise FulfilmentNotRecorded, fulfilment_not_recorded_message(current)
    end

    # Shared by the authorization gate, the fulfilment gate, and the
    # alternate-resource gate. Reads the referral the current identifier
    # will link, and does not assign the association. A blank stored link
    # is read the same way, including an already-sent claim whose
    # identifier is unchanged. The gated save assigns it. A plain save
    # does not.
    def referral_for_submission_gates
      return unambiguous_patient_referral if prc_referral_id.blank? || referral_link_inputs_changed?

      prc_referral
    end

    def fulfilment_not_recorded_message(referral)
      fulfilment = Corvid::ReferralFulfilment.status(referral)
      "Claim for referral #{referral.referral_identifier} cannot be submitted: " \
        "fulfilment is #{fulfilment}; delivered care has not been recorded"
    end

    # A linked referral is re-verified for service_date before the claim is
    # sent. No linked PRC referral is ordinary billing and skips this gate.
    # A nil service date fails closed. The referral is
    # referral_for_submission_gates, the same resolution the authorization
    # and fulfilment gates use. The association is not assigned before
    # deciding: a dirty referral_identifier must not be judged against the
    # referral this claim used to name, and a refusal must not retarget
    # the link. A blank link is read for this decision without assigning
    # it, including an already-sent claim. The gated save links it. A
    # plain save does not.
    def enforce_alternate_resources_current!
      referral = referral_for_submission_gates
      return if referral.nil?
      return if alternate_resources_current?(referral)

      raise AlternateResourcesNotCurrent
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
    # ambiguously, matches another patient's referral, or matches this
    # patient's referral before it is authorized. There a PRC referral
    # demonstrably exists and we cannot establish that the one being billed
    # was authorized.
    #
    # The referral is referral_for_submission_gates, the same resolution the
    # fulfilment gate uses. The association is not assigned before deciding:
    # a dirty referral_identifier must not be judged against the referral
    # this claim used to name, and a refusal must not retarget the link.
    # The resolver still runs on save, so a claim can reach this gate with
    # prc_referral_id NULL.
    def enforce_referral_authorization_gate!
      referral = referral_for_submission_gates

      if referral.blank?
        raise ReferralNotAuthorized,
          "Claim naming referral #{referral_identifier} cannot be submitted: " \
          "a PRC referral exists under that identifier at this facility but it " \
          "is not this patient's, or several share it, so the authorization " \
          "behind this bill cannot be established" if conflicting_referral_match?

        return
      end

      # Re-read before deciding. Authorizing care can happen between loading
      # a claim and submitting it. Reload does not assign the association.
      current = referral.reload
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
