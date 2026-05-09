# frozen_string_literal: true

module Corvid
  # Tracks 837P/I/D claims through lifecycle from draft to paid.
  # Ported from rpms_redux. Uses adapter pattern for clearinghouse
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

    validates :patient_identifier, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :claim_type, inclusion: { in: CLAIM_TYPES }

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
