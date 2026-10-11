# frozen_string_literal: true

# Query log for Indian health eligibility inquiries (ADR 0008).
# One row per inquiry. asserted_at is ISO-8601 text so a replay can return
# the provider's original instant.
class CreateCorvidIndianHealthEligibilityInquiries < ActiveRecord::Migration[8.1]
  ANSWERS = %w[eligible not_eligible unknown unavailable refused].freeze

  def change
    create_table :corvid_indian_health_eligibility_inquiries do |t|
      t.string :tenant_identifier, null: false
      t.string :requester_identifier, null: false
      t.string :agreement_reference, null: false
      t.string :person_identifier, null: false
      t.string :answer, null: false
      t.string :data_source
      t.string :asserted_at
      t.string :message_id, null: false
      t.boolean :replayed, null: false, default: false

      t.timestamps
    end

    add_index :corvid_indian_health_eligibility_inquiries, :message_id,
      unique: true, name: "idx_corvid_ihe_inquiries_message_id"
    add_index :corvid_indian_health_eligibility_inquiries,
      [ :tenant_identifier, :person_identifier, :created_at ],
      name: "idx_corvid_ihe_inquiries_tenant_person_created"
    add_index :corvid_indian_health_eligibility_inquiries,
      [ :tenant_identifier, :requester_identifier, :created_at ],
      name: "idx_corvid_ihe_inquiries_tenant_requester_created"

    add_check_constraint :corvid_indian_health_eligibility_inquiries,
      "answer IN (#{ANSWERS.map { |answer| "'#{answer}'" }.join(",")})",
      name: "corvid_ihe_inquiries_answer_check"
  end
end
