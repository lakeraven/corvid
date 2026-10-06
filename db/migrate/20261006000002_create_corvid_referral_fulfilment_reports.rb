# frozen_string_literal: true

# corvid#595: fulfilment facts originate OUTSIDE this engine — a receiving
# specialist, or a patient confirming an appointment. Each report is an
# append-only record of one such external report; the referral's current
# fulfilment status is derived (most recent report wins), never cached or
# inferred from anything else (a claim arriving does not count). No row
# in this table is ever written by claim/billing code.
class CreateCorvidReferralFulfilmentReports < ActiveRecord::Migration[8.1]
  SOURCES = %w[receiving_specialist patient staff other].freeze
  OUTCOMES = %w[delivered not_delivered].freeze

  def change
    create_table :corvid_referral_fulfilment_reports do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :prc_referral, null: false,
                    foreign_key: { to_table: :corvid_prc_referrals }
      t.string :source, null: false
      t.string :outcome, null: false
      t.datetime :reported_at, null: false
      t.string :detail_token

      t.timestamps
    end

    add_index :corvid_referral_fulfilment_reports,
              [ :tenant_identifier, :prc_referral_id ],
              name: "idx_corvid_fulfilment_reports_tenant_referral"
    add_index :corvid_referral_fulfilment_reports,
              [ :prc_referral_id, :reported_at ],
              name: "idx_corvid_fulfilment_reports_referral_reported_at"

    add_check_constraint :corvid_referral_fulfilment_reports,
      "source IN (#{SOURCES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_fulfilment_reports_source_check"
    add_check_constraint :corvid_referral_fulfilment_reports,
      "outcome IN (#{OUTCOMES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_fulfilment_reports_outcome_check"
  end
end
