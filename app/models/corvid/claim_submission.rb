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

    scope :by_status, ->(status) { where(status: status) }
    scope :pending, -> { where(status: %w[submitted accepted]) }
    scope :paid, -> { where(status: "paid") }
    scope :rejected, -> { where(status: %w[rejected denied]) }
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

    def self.acceptance_rate
      finalized = where(status: %w[paid rejected denied]).count
      return 0.0 if finalized == 0

      paid_count = where(status: "paid").count
      (paid_count.to_f / finalized * 100).round(1)
    end

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
      %w[rejected denied].include?(status)
    end

    def pending?
      %w[submitted accepted].include?(status)
    end

    def mark_submitted!(claim_identifier:)
      update!(
        claim_identifier: claim_identifier,
        status: "submitted",
        submitted_at: Time.current
      )
    end

    def mark_paid!(paid_amount:)
      update!(status: "paid", paid_amount: paid_amount)
    end

    def mark_rejected!(reason_token:)
      update!(status: "rejected", denial_reason_token: reason_token)
    end

    def submit!
      enforce_referral_authorization_gate!
      result = Corvid.adapter.submit_claim(to_claim_data)
      update!(
        claim_identifier: result[:claim_identifier],
        status: result[:status] == "accepted" ? "submitted" : result[:status],
        submitted_at: Time.current
      )
      result
    end

    def check_status!
      return unless claim_identifier
      result = Corvid.adapter.check_claim_status(claim_identifier)
      attrs = { last_checked_at: Time.current }
      attrs[:status] = result[:status] if STATUSES.include?(result[:status])
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
