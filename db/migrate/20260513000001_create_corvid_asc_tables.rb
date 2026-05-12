# frozen_string_literal: true

# CMS Ambulatory Surgical Center (ASC) payment tables. ASC payment
# parallels OPPS structurally — APC weight × conversion factor × wage
# index — but uses ASC-specific weights (CMS Addendum AA differs from
# OPPS Addendum B for some APCs) and an ASC conversion factor that
# runs roughly 60% of the OPPS CF. The analyzer routes outpatient
# obligations to ASC when the vendor is in corvid_asc_facilities.
class CreateCorvidAscTables < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_asc_apc_weights do |t|
      t.integer :calendar_year, null: false
      t.string :apc_code, null: false
      t.decimal :relative_weight, precision: 8, scale: 4, null: false
      t.string :release_label
      t.timestamps
    end
    add_index :corvid_asc_apc_weights,
              [ :calendar_year, :apc_code ],
              unique: true,
              name: "idx_corvid_asc_apc_weights_cy_apc"

    create_table :corvid_asc_conversion_factors do |t|
      t.integer :calendar_year, null: false
      t.string :locality, null: false
      t.decimal :conversion_factor, precision: 12, scale: 4, null: false
      t.decimal :wage_index, precision: 8, scale: 4, null: false, default: 1.0
      t.string :release_label
      t.timestamps
    end
    add_index :corvid_asc_conversion_factors,
              [ :calendar_year, :locality ],
              unique: true,
              name: "idx_corvid_asc_conversion_factors_cy_locality"

    # Vendor registry — when an obligation's vendor_id (CCN or NPI)
    # matches an active row on the service date, the analyzer routes
    # the outpatient claim through AscRateProvider instead of OPPS.
    # Either ccn or npi must be present (model-level validation);
    # NPI-only rows are legitimate match targets. Partial unique
    # indexes enforce no-overlap on each identifier independently.
    create_table :corvid_asc_facilities do |t|
      t.string :ccn
      t.string :npi
      t.string :facility_name
      t.date :effective_date, null: false
      t.date :end_date
      t.string :source_release
      t.timestamps
    end
    add_index :corvid_asc_facilities, [ :ccn, :effective_date ], unique: true,
              where: "ccn IS NOT NULL",
              name: "idx_corvid_asc_ccn_effective"
    add_index :corvid_asc_facilities, [ :npi, :effective_date ], unique: true,
              where: "npi IS NOT NULL",
              name: "idx_corvid_asc_npi_effective"
  end
end
