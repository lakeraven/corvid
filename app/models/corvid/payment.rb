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

      event :start_processing do
        transitions from: :pending, to: :processing
      end

      event :succeed do
        transitions from: :processing, to: :succeeded
      end

      event :fail do
        transitions from: [:pending, :processing], to: :failed
      end

      event :refund do
        transitions from: :succeeded, to: :refunded
      end
    end

    def amount_dollars
      amount_cents / 100.0
    end

    def mark_processing!(payment_identifier:)
      start_processing!
      update!(payment_identifier: payment_identifier)
    end

    def mark_succeeded!(receipt_url: nil)
      succeed!
      update!(receipt_url: receipt_url) if receipt_url
    end

    def mark_failed!(message: nil)
      fail!
    end

    def mark_refunded!
      refund!
    end

    def refundable?
      succeeded? && payment_identifier.present?
    end

    def process_via_adapter!
      result = Corvid.adapter.process_payment(
        amount_cents: amount_cents,
        patient_identifier: patient_identifier,
        description: description
      )
      mark_processing!(payment_identifier: result[:payment_identifier])
      result
    end

    def refund_via_adapter!
      return unless refundable?

      result = Corvid.adapter.refund_payment(payment_identifier)
      mark_refunded! if result[:status] == "refunded"
      result
    end
  end
end
