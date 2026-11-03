# frozen_string_literal: true

# CMS labor-related shares for OPPS and ASC wage adjustment (#722).
# Reference data, like corvid_opps_conversion_factors: no tenant columns.
# payment_system is a string enum guarded by a CHECK (ADR 0002).
# labor_share is strictly between 0 and 1 — a missing row is undetermined,
# never a silent 100% labor share.
class CreateCorvidCmsLaborShares < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_cms_labor_shares do |t|
      t.string :payment_system, null: false
      t.integer :calendar_year, null: false
      t.decimal :labor_share, precision: 5, scale: 4, null: false
      t.string :source, null: false
      t.string :release_label
      t.timestamps
    end

    add_index :corvid_cms_labor_shares,
              [ :payment_system, :calendar_year ],
              unique: true,
              name: "idx_corvid_cms_labor_shares_system_year"

    add_check_constraint :corvid_cms_labor_shares,
                         "payment_system IN ('opps', 'asc')",
                         name: "corvid_cms_labor_shares_payment_system_check"
    add_check_constraint :corvid_cms_labor_shares,
                         "labor_share > 0 AND labor_share < 1",
                         name: "corvid_cms_labor_shares_labor_share_check"
  end
end
