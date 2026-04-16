# frozen_string_literal: true

class CreateCorvidApiCallLogs < ActiveRecord::Migration[8.1]
  # CMS-0057-F recognized APIs. Each API carries its own required public
  # reporting metrics (see 45 CFR 156.223).
  API_NAMES = %w[pas patient_access provider_access payer_to_payer].freeze

  def change
    create_table :corvid_api_call_logs do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :api_name, null: false
      t.string :endpoint, null: false
      t.string :patient_identifier
      t.string :app_identifier
      t.datetime :called_at, null: false
      t.timestamps
    end

    add_index :corvid_api_call_logs, [ :tenant_identifier, :api_name, :called_at ],
      name: "idx_corvid_api_calls_tenant_api_time"
    add_index :corvid_api_call_logs, [ :tenant_identifier, :api_name, :patient_identifier ],
      name: "idx_corvid_api_calls_tenant_patient"
    add_index :corvid_api_call_logs, [ :tenant_identifier, :api_name, :app_identifier ],
      name: "idx_corvid_api_calls_tenant_app"

    add_check_constraint :corvid_api_call_logs,
      "api_name IN (#{API_NAMES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_api_call_logs_api_name_check"
  end
end
