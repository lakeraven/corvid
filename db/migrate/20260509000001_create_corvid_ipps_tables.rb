# frozen_string_literal: true

class CreateCorvidIppsTables < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_ipps_drg_weights do |t|
      t.integer :fiscal_year, null: false
      t.string :drg_code, null: false
      t.decimal :relative_weight, precision: 8, scale: 4, null: false
      t.timestamps
    end

    add_index :corvid_ipps_drg_weights,
              [ :fiscal_year, :drg_code ],
              unique: true,
              name: "idx_corvid_ipps_drg_weights_fy_drg"

    create_table :corvid_ipps_hospital_rates do |t|
      t.integer :fiscal_year, null: false
      # `locality` is either the PFS locality code (matching ZipLocality
      # rows used by PFS repricing) or "NATIONAL" for the default-row
      # fallback the rate provider uses when a locality-specific row
      # isn't loaded.
      t.string :locality, null: false
      t.decimal :base_rate, precision: 12, scale: 2, null: false
      t.decimal :wage_index, precision: 8, scale: 4, null: false, default: 1.0
      t.timestamps
    end

    add_index :corvid_ipps_hospital_rates,
              [ :fiscal_year, :locality ],
              unique: true,
              name: "idx_corvid_ipps_hospital_rates_fy_locality"
  end
end
