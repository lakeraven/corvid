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

    # annual_report queries filter by (tenant, api, called_at range) first,
    # then aggregate distinct patient/app. Leading tenant+api+called_at
    # narrows to the year window; trailing patient_identifier / app_identifier
    # lets PG answer the count(distinct ...) from the index alone.
    add_index :corvid_api_call_logs,
      [ :tenant_identifier, :api_name, :called_at, :patient_identifier ],
      name: "idx_corvid_api_calls_tenant_api_time_patient"
    add_index :corvid_api_call_logs,
      [ :tenant_identifier, :api_name, :called_at, :app_identifier ],
      name: "idx_corvid_api_calls_tenant_api_time_app"
    add_index :corvid_api_call_logs,
      [ :tenant_identifier, :api_name, :endpoint, :called_at ],
      name: "idx_corvid_api_calls_tenant_api_endpoint_time"

    add_check_constraint :corvid_api_call_logs,
      "api_name IN (#{API_NAMES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_api_call_logs_api_name_check"
  end
end
