# frozen_string_literal: true

class CreateCorvidOppsTables < ActiveRecord::Migration[8.1]
  def change
    # APC relative weight by year. Calendar year for OPPS (Jan 1 boundary)
    # — different from IPPS which uses federal fiscal year.
    create_table :corvid_opps_apc_weights do |t|
      t.integer :calendar_year, null: false
      t.string :apc_code, null: false
      t.decimal :relative_weight, precision: 8, scale: 4, null: false
      t.string :release_label
      t.timestamps
    end

    add_index :corvid_opps_apc_weights,
              [ :calendar_year, :apc_code ],
              unique: true,
              name: "idx_corvid_opps_apc_weights_cy_apc"

    # OPPS conversion factor by year + locality. `locality` is either the
    # PFS locality code or "NATIONAL" for the default-row fallback.
    # OPPS payment formula: relative_weight × conversion_factor × wage_index_adjustment
    create_table :corvid_opps_conversion_factors do |t|
      t.integer :calendar_year, null: false
      t.string :locality, null: false
      t.decimal :conversion_factor, precision: 12, scale: 4, null: false
      t.decimal :wage_index, precision: 8, scale: 4, null: false, default: 1.0
      t.string :release_label
      t.timestamps
    end

    add_index :corvid_opps_conversion_factors,
              [ :calendar_year, :locality ],
              unique: true,
              name: "idx_corvid_opps_conversion_factors_cy_locality"
  end
end
