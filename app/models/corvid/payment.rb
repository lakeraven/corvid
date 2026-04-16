# frozen_string_literal: true

module Corvid
  # Payment records for copays, balances, and patient responsibility.
  # Payment processing via adapter (Stripe implementation in private repo).
  class Payment < ::ActiveRecord::Base
    self.table_name = "corvid_payments"

    include TenantScoped

    STATUSES = %w[pending processing succeeded failed refunded].freeze

    validates :patient_identifier, presence: true
    validates :amount_cents, presence: true, numericality: { greater_than: 0 }
    validates :status, inclusion: { in: STATUSES }

    scope :by_status, ->(status) { where(status: status) }
    scope :succeeded, -> { where(status: "succeeded") }
    scope :for_patient, ->(id) { where(patient_identifier: id) }

    def amount_dollars
      amount_cents / 100.0
    end

    def process!
      result = Corvid.adapter.process_payment(
        amount_cents: amount_cents,
        patient_identifier: patient_identifier,
        description: description
      )
      update!(
        payment_identifier: result[:payment_identifier],
        status: result[:status]
      )
      result
    end

    def refund!
      return unless payment_identifier
      result = Corvid.adapter.refund_payment(payment_identifier)
      update!(status: "refunded") if result[:status] == "refunded"
      result
    end
  end
end
