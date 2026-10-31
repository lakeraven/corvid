# frozen_string_literal: true

# Which system bills a facility: Corvid or the EHR. A null visit_type
# covers every visit. Effective ranges for one tenant, facility, and
# visit type cannot overlap. btree_gist is required because the
# exclusion mixes equality with daterange overlap. An open expires_on
# is an unbounded range, so it overlaps every later date. ADR 0002
# string enum; ADR 0003 no free text.
class CreateCorvidBillingSystemSettings < ActiveRecord::Migration[8.1]
  # '' is not a visit type (see the CHECK). COALESCE makes a null
  # visit_type one value, so two all-visits rows conflict.
  NO_OVERLAP = <<~SQL.squish
    tenant_identifier WITH =,
    facility_identifier WITH =,
    COALESCE(visit_type, '') WITH =,
    daterange(effective_on, expires_on, '[]') WITH &&
  SQL

  def change
    # Enabling is idempotent. Rollback leaves the extension in place:
    # DROP EXTENSION fails when another object depends on it, and would
    # remove an extension the host database may already have enabled.
    reversible do |dir|
      dir.up do
        enable_extension "btree_gist" unless extension_enabled?("btree_gist")
      end
    end

    create_table :corvid_billing_system_settings do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier, null: false
      t.string :visit_type
      t.string :system_of_record, null: false
      t.date :effective_on, null: false
      t.date :expires_on
      t.timestamps
    end

    add_index :corvid_billing_system_settings,
              [ :tenant_identifier, :facility_identifier ],
              name: "idx_corvid_billing_system_settings_tenant_facility"

    add_check_constraint :corvid_billing_system_settings,
                         "system_of_record IN ('corvid', 'ehr')",
                         name: "corvid_billing_system_settings_system_of_record_check"
    add_check_constraint :corvid_billing_system_settings,
                         "expires_on IS NULL OR expires_on >= effective_on",
                         name: "corvid_billing_system_settings_expires_on_check"
    add_check_constraint :corvid_billing_system_settings,
                         "visit_type IS NULL OR btrim(visit_type) <> ''",
                         name: "corvid_billing_system_settings_visit_type_check"

    add_exclusion_constraint :corvid_billing_system_settings, NO_OVERLAP,
                             using: :gist,
                             name: "corvid_billing_system_settings_no_overlap"
  end
end
