# frozen_string_literal: true

class CreateCorvidTenantConnectionConfigs < ActiveRecord::Migration[8.1]
  ADAPTER_TYPES = %w[rpms_direct rpms_connector fhir mock].freeze

  def change
    # Per-tenant (optionally per-facility) adapter routing config, per
    # ADR 0006 Decision 4 / issue #390. AdapterRouter.resolve looks up a
    # row here, resolves `secret_ref` via Corvid.configuration.secret_reader,
    # and hands the result to AdapterFactory.build. `secret_ref` is always
    # a reference (an ENV var name, a Vault path, ...) — never a literal
    # credential; per ADR 0006 Decision 3, real RPMS credentials for Mode 3
    # (customer-side connector) never reach this table or corvid SaaS at all.
    create_table :corvid_tenant_connection_configs do |t|
      t.string :tenant_identifier, null: false
      # NULL facility_identifier is the tenant-wide default config, used
      # when no facility-specific row matches (see .for in the model).
      t.string :facility_identifier
      t.string :adapter_type, null: false
      t.string :endpoint
      t.string :secret_ref
      # Connector enrollment identity for ADR 0006 Mode 3 (rpms_connector);
      # unused by mode/adapter types that don't need it.
      t.string :connector_id
      # Adapter-specific extra kwargs not modeled as columns (e.g. FHIR
      # open_timeout/read_timeout/proxy_uri). Merged into the builder call
      # by AdapterFactory.
      t.jsonb :config, null: false, default: {}
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :corvid_tenant_connection_configs,
              :tenant_identifier,
              unique: true,
              where: "facility_identifier IS NULL",
              name: "idx_corvid_tcc_tenant_default_unique"

    add_index :corvid_tenant_connection_configs,
              [ :tenant_identifier, :facility_identifier ],
              unique: true,
              where: "facility_identifier IS NOT NULL",
              name: "idx_corvid_tcc_tenant_facility_unique"

    add_check_constraint :corvid_tenant_connection_configs,
                          "adapter_type IN (#{ADAPTER_TYPES.map { |t| "'#{t}'" }.join(',')})",
                          name: "corvid_tenant_connection_configs_adapter_type_check"
  end
end
