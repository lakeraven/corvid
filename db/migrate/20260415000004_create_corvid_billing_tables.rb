# frozen_string_literal: true

class CreateCorvidBillingTables < ActiveRecord::Migration[8.1]
  CLAIM_STATUSES = %w[draft submitted accepted rejected paid denied appealed].freeze
  TRANSACTION_TYPES = %w[eligibility claim claim_status remittance payment].freeze
  TRANSACTION_DIRECTIONS = %w[inbound outbound].freeze
  PAYMENT_STATUSES = %w[pending processing succeeded failed refunded].freeze

  def change
    create_table :corvid_billing_transactions do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :transaction_type, null: false
      t.string :direction, null: false, default: "outbound"
      t.string :status, null: false, default: "pending"
      t.string :reference_identifier
      t.string :patient_identifier
      t.string :request_token
      t.string :response_token
      t.string :error_message
      t.timestamps
    end
    add_index :corvid_billing_transactions, [:tenant_identifier, :transaction_type]
    add_index :corvid_billing_transactions, [:tenant_identifier, :reference_identifier]
    add_check_constraint :corvid_billing_transactions,
      "transaction_type IN (#{TRANSACTION_TYPES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_billing_tx_type_check"
    add_check_constraint :corvid_billing_transactions,
      "direction IN (#{TRANSACTION_DIRECTIONS.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_billing_tx_direction_check"

    create_table :corvid_claim_submissions do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :patient_identifier, null: false
      t.string :referral_identifier
      t.string :claim_reference
      t.string :claim_type, null: false, default: "professional"
      t.string :status, null: false, default: "draft"
      t.decimal :billed_amount, precision: 12, scale: 2
      t.decimal :paid_amount, precision: 12, scale: 2
      t.decimal :adjustment_amount, precision: 12, scale: 2
      t.decimal :patient_responsibility, precision: 12, scale: 2
      t.string :payer_identifier
      t.string :payer_name_token
      t.string :diagnosis_codes_token
      t.string :procedure_codes_token
      t.date :service_date
      t.date :paid_date
      t.datetime :submitted_at
      t.datetime :last_checked_at
      t.string :denial_reason_token
      t.string :provider_identifier
      t.string :provider_type
      t.decimal :state_share, precision: 12, scale: 2
      t.decimal :county_share, precision: 12, scale: 2
      t.timestamps
    end
    add_index :corvid_claim_submissions, [:tenant_identifier, :status]
    add_index :corvid_claim_submissions, [:tenant_identifier, :patient_identifier]
    add_index :corvid_claim_submissions, :claim_reference, unique: true
    add_check_constraint :corvid_claim_submissions,
      "status IN (#{CLAIM_STATUSES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_claim_submissions_status_check"

    create_table :corvid_payments do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :patient_identifier, null: false
      t.string :payment_reference
      t.integer :amount_cents, null: false
      t.string :status, null: false, default: "pending"
      t.string :description
      t.string :claim_submission_id
      t.timestamps
    end
    add_index :corvid_payments, [:tenant_identifier, :status]
    add_index :corvid_payments, [:tenant_identifier, :patient_identifier]
    add_index :corvid_payments, :payment_reference, unique: true
    add_check_constraint :corvid_payments,
      "status IN (#{PAYMENT_STATUSES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_payments_status_check"
  end
end
