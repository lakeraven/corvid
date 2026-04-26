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

    STATUSES = %w[pending completed failed].freeze

    validates :transaction_type, presence: true, inclusion: { in: TRANSACTION_TYPES }
    validates :direction, presence: true, inclusion: { in: DIRECTIONS }
    validates :status, inclusion: { in: STATUSES }

    scope :by_type, ->(type) { where(transaction_type: type) }
    scope :by_direction, ->(dir) { where(direction: dir) }
    scope :by_status, ->(status) { where(status: status) }
    scope :for_patient, ->(identifier) { where(patient_identifier: identifier) }
    scope :recent, -> { order(created_at: :desc) }
    scope :eligibility, -> { by_type("eligibility") }
    scope :claims, -> { by_type("claim") }
    scope :successful, -> { by_status("completed") }
    scope :failed_transactions, -> { by_status("failed") }
    scope :since, ->(time) { where("created_at >= ?", time) }

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

    def self.success_rate
      total = count
      return 0 if total == 0

      successful = where(status: "completed").count
      (successful.to_f / total * 100).round(1)
    end

    def self.by_type_counts
      group(:transaction_type).count
    end

    # Instance methods
    def success?
      status == "completed"
    end

    def failed?
      status == "failed"
    end

    def pending?
      status == "pending"
    end

    def eligibility?
      transaction_type == "eligibility"
    end

    def claim?
      transaction_type == "claim"
    end

    def mark_success!(response_token: nil)
      update!(status: "completed", response_token: response_token)
    end

    def mark_error!(message)
      update!(status: "failed", error_message: message)
    end
  end
end
