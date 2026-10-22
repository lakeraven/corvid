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
    # Draft has not been sent. Error has not been sent unless the row
    # already stores a claim_identifier or submitted_at: the adapter
    # identified the claim, or a submission time was stamped. A plain
    # save cannot move a PRC-linked claim from an unsent status into a
    # sent status, and cannot set status to "submitted" from any status.
    # submit! and mark_submitted! are the only paths that do, and they
    # re-run the gates. Later moves among sent statuses, including an
    # error that was actually sent, do not depend on submitted_at. A row
    # created already sent is a historical import and is left unstamped.
    UNSENT_STATUSES = %w[draft error].freeze
    SENT_STATUSES = %w[submitted accepted rejected paid denied appealed].freeze

    # Raised by #submit! when this claim bills a PRC referral that has not been
    # authorized. PRC authorizes before care is purchased, so billing an
    # unauthorized referral bills care the programme never agreed to buy.
    class ReferralNotAuthorized < StandardError; end

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
    before_validation :resolve_prc_referral_from_identifier,
      if: :referral_link_inputs_changed?

    # Every path into rejected or denied (submit!, check_status!, the mark_*
    # helpers, remittance processing) records when it first happened, so the
    # KPIs above still count the claim after its status moves on.
    before_save :stamp_rejection_and_denial_times, if: :will_save_change_to_status?

    validate :submission_status_requires_gate, on: :update

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
      # Same order as submit!: an unauthorized referral is refused before
      # any payer re-verification.
      enforce_referral_authorization_gate!
      enforce_alternate_resources_current!
      saved = save_through_submission_gate!(
        claim_identifier: claim_identifier,
        status: "submitted",
        submitted_at: Time.current
      )
      record_submission_provenance
      saved
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
      enforce_alternate_resources_current!
      result = Corvid.adapter.submit_claim(to_claim_data)
      save_through_submission_gate!(
        claim_identifier: result[:claim_identifier],
        status: result[:status] == "accepted" ? "submitted" : result[:status],
        submitted_at: Time.current
      )
      record_submission_provenance
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

    # PRC-linked claims: only submit! and mark_submitted! may enter
    # "submitted", from any stored status. A plain save also cannot leave
    # an unsent row — draft, or error with neither claim_identifier nor
    # submitted_at — for a sent status. An error that already has either
    # was sent; a status poll, payment, or remittance may move it. Moves
    # between sent statuses stay open whether or not submitted_at was
    # stamped. Creating a row already sent is a historical import and is
    # not validated here.
    def submission_status_requires_gate
      return if @submission_through_gate
      return unless guarded_status_transition?

      errors.add(:status, "must be submitted with submit! or mark_submitted!")
    end

    def guarded_status_transition?
      prc_referral_id.present? && will_save_change_to_status? && submission_transition_blocked?
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
    # claim_identifier was assigned, or submitted_at was stamped.
    def sent_despite_error_status?
      status_in_database == "error" &&
        (claim_identifier_in_database.present? || submitted_at_in_database.present?)
    end

    def save_through_submission_gate!(attributes)
      @submission_through_gate = true
      update!(attributes)
    ensure
      @submission_through_gate = false
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

    def record_submission_provenance
      return if prc_referral.blank?

      AlternateResourceReverification.record!(
        self,
        activity: "CREATE",
        checks: prc_referral.alternate_resource_checks.reload
      )
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
