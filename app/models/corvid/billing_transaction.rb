# frozen_string_literal: true

module Corvid
  # Audit log for all clearinghouse/EDI interactions.
  # Tracks 270/271 eligibility, 837 claims, 276/277 status, 835 remittance.
  # PHI stored via tokens per ADR 0003.
  class BillingTransaction < ::ActiveRecord::Base
    self.table_name = "corvid_billing_transactions"

    include TenantScoped

    TRANSACTION_TYPES = %w[eligibility claim claim_status remittance payment].freeze
    DIRECTIONS = %w[inbound outbound].freeze

    validates :transaction_type, inclusion: { in: TRANSACTION_TYPES }
    validates :direction, inclusion: { in: DIRECTIONS }

    scope :by_type, ->(type) { where(transaction_type: type) }
    scope :by_direction, ->(dir) { where(direction: dir) }
    scope :by_status, ->(status) { where(status: status) }
    scope :for_patient, ->(identifier) { where(patient_identifier: identifier) }
    scope :recent, -> { order(created_at: :desc) }

    def self.log_transaction!(tenant:, facility: nil, type:, direction: "outbound", reference: nil, patient: nil, request_token: nil, response_token: nil, status: "completed", error: nil)
      create!(
        tenant_identifier: tenant,
        facility_identifier: facility,
        transaction_type: type,
        direction: direction,
        reference_identifier: reference,
        patient_identifier: patient,
        request_token: request_token,
        response_token: response_token,
        status: status,
        error_message: error
      )
    end
  end
end
