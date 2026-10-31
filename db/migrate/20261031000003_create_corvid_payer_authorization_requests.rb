# frozen_string_literal: true

# Payer prior-authorization requests (#793). The number the payer assigns
# is stored here and is not the referral's PRC authorization_number.
# Channel and status are closed string sets (ADR 0002). A draft can be
# cancelled without a sign-off; every status that means the payer was
# asked requires submitted_at and a non-blank sign-off. An approval
# requires the payer's authorization id and a real date range. Empty
# strings are not identifiers (ADR 0001, ADR 0003).
class CreateCorvidPayerAuthorizationRequests < ActiveRecord::Migration[8.1]
  CHANNELS = %w[pas x12_278 portal fax].freeze
  STATUSES = %w[drafted submitted pended approved partially_approved denied cancelled].freeze
  # Cancelled is included because a draft may be withdrawn before anyone
  # submits it. submitted/pended/approved/partially_approved/denied all
  # mean the request was sent, so they are not in this list.
  NO_SUBMISSION_STATUSES = %w[drafted cancelled].freeze
  APPROVED_STATUSES = %w[approved partially_approved].freeze

  def change
    create_payer_authorization_requests
    add_payer_authorization_indexes
    add_payer_authorization_checks
  end

  private

  def create_payer_authorization_requests
    create_table :corvid_payer_authorization_requests do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :prc_referral, foreign_key: { to_table: :corvid_prc_referrals }
      t.string :payer_identifier, null: false
      t.string :channel, null: false
      t.string :status, null: false, default: "drafted"
      t.datetime :submitted_at
      t.string :submitted_by_identifier
      t.datetime :follow_up_due_at
      t.string :payer_authorization_identifier
      t.integer :approved_units
      t.date :approved_from
      t.date :approved_to
      t.timestamps
    end
  end

  def add_payer_authorization_indexes
    add_index :corvid_payer_authorization_requests, [ :tenant_identifier, :facility_identifier ],
      name: "idx_corvid_payer_auth_requests_tenant_facility"
    add_index :corvid_payer_authorization_requests, [ :tenant_identifier, :status ],
      name: "idx_corvid_payer_auth_requests_tenant_status"
    add_index :corvid_payer_authorization_requests, [ :tenant_identifier, :follow_up_due_at ],
      name: "idx_corvid_payer_auth_requests_tenant_follow_up"
    add_index :corvid_payer_authorization_requests, [ :tenant_identifier, :approved_to ],
      name: "idx_corvid_payer_auth_requests_tenant_approved_to"
  end

  def add_payer_authorization_checks
    add_check_constraint :corvid_payer_authorization_requests, in_list("channel", CHANNELS),
      name: "corvid_payer_auth_requests_channel_check"
    add_check_constraint :corvid_payer_authorization_requests, in_list("status", STATUSES),
      name: "corvid_payer_auth_requests_status_check"
    add_check_constraint :corvid_payer_authorization_requests, submission_sql,
      name: "corvid_payer_auth_requests_submitted_check"
    add_check_constraint :corvid_payer_authorization_requests, approval_sql,
      name: "corvid_payer_auth_requests_approval_check"
    add_check_constraint :corvid_payer_authorization_requests, approved_range_sql,
      name: "corvid_payer_auth_requests_approved_range_check"
    add_check_constraint :corvid_payer_authorization_requests, approved_units_sql,
      name: "corvid_payer_auth_requests_approved_units_check"
    add_check_constraint :corvid_payer_authorization_requests, identifiers_sql,
      name: "corvid_payer_auth_requests_identifiers_check"
  end

  def submission_sql
    "#{in_list("status", NO_SUBMISSION_STATUSES)} OR (" \
      "submitted_at IS NOT NULL AND submitted_by_identifier IS NOT NULL AND " \
      "btrim(submitted_by_identifier) <> '')"
  end

  def approval_sql
    "status NOT IN (#{quoted(APPROVED_STATUSES)}) OR (" \
      "payer_authorization_identifier IS NOT NULL AND btrim(payer_authorization_identifier) <> '' AND " \
      "approved_from IS NOT NULL AND approved_to IS NOT NULL)"
  end

  def approved_range_sql
    "approved_from IS NULL OR approved_to IS NULL OR approved_to >= approved_from"
  end

  def approved_units_sql
    "approved_units IS NULL OR approved_units > 0"
  end

  def identifiers_sql
    "btrim(tenant_identifier) <> '' AND btrim(payer_identifier) <> '' AND " \
      "(facility_identifier IS NULL OR btrim(facility_identifier) <> '') AND " \
      "(submitted_by_identifier IS NULL OR btrim(submitted_by_identifier) <> '') AND " \
      "(payer_authorization_identifier IS NULL OR btrim(payer_authorization_identifier) <> '')"
  end

  def in_list(column, values)
    "#{column} IN (#{quoted(values)})"
  end

  def quoted(values)
    values.map { |value| connection.quote(value) }.join(",")
  end
end
