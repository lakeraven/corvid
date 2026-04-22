# frozen_string_literal: true

module Corvid
  # Payment records for copays, balances, and patient responsibility.
  # Payment processing via adapter (Stripe implementation in private repo).
  class Payment < ::ActiveRecord::Base
    self.table_name = "corvid_payments"

    include TenantScoped
    include AASM

    validates :patient_identifier, presence: true
    validates :amount_cents, presence: true, numericality: { greater_than: 0 }

    scope :by_status, ->(status) { where(status: status) }
    scope :succeeded, -> { where(status: "succeeded") }
    scope :for_patient, ->(id) { where(patient_identifier: id) }

    aasm column: :status do
      state :pending, initial: true
      state :processing, :succeeded, :failed, :refunded

      event :begin_processing do
        transitions from: :pending, to: :processing
      end

      event :mark_succeeded do
        transitions from: :processing, to: :succeeded
      end

      event :mark_failed do
        transitions from: [:pending, :processing], to: :failed
      end

      event :mark_refunded do
        transitions from: :succeeded, to: :refunded
      end
    end

    def amount_dollars
      amount_cents / 100.0
    end

    def refundable?
      succeeded? && payment_identifier.present?
    end

    # -- Public API (called by steps/controllers) ----------------------------

    def process!
      result = Corvid.adapter.process_payment(
        amount_cents: amount_cents,
        patient_identifier: patient_identifier,
        description: description
      )

      if result[:status] == "failed" || result[:error]
        mark_failed!
      else
        begin_processing!
        update!(payment_identifier: result[:payment_identifier])
      end

      result
    rescue => e
      mark_failed!
      { status: "failed", error: e.message }
    end

    def refund!
      return { status: "error", message: "Not refundable" } unless refundable?

      result = Corvid.adapter.refund_payment(payment_identifier)
      mark_refunded! if result[:status] == "refunded"
      result
    end

    # -- Convenience for webhook/async callbacks -----------------------------

    def confirm_succeeded!(receipt_url: nil)
      mark_succeeded!
      update!(receipt_url: receipt_url) if receipt_url
    end

    def confirm_failed!(message: nil)
      mark_failed!
    end
  end
end
