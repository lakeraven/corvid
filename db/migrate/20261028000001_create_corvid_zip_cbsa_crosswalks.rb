# frozen_string_literal: true

# ZIP → CBSA wage-area crosswalk for one federal fiscal year.
# Urban CBSA codes are 5 ASCII digits; rural areas are the 2-digit
# CMS state code. CHECK constraints match ZipCbsaCrosswalk so a raw
# insert cannot store a value the model rejects (ADR 0002).
class CreateCorvidZipCbsaCrosswalks < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_zip_cbsa_crosswalks do |t|
      t.integer :fiscal_year, null: false
      t.string :zip, null: false
      t.string :cbsa, null: false
      t.string :release_label
      t.timestamps
    end

    add_index :corvid_zip_cbsa_crosswalks,
              [ :fiscal_year, :zip ],
              unique: true,
              name: "idx_corvid_zip_cbsa_crosswalks_fy_zip"

    add_check_constraint :corvid_zip_cbsa_crosswalks,
                         "zip ~ '^[0-9]{5}$'",
                         name: "corvid_zip_cbsa_crosswalks_zip_check"
    add_check_constraint :corvid_zip_cbsa_crosswalks,
                         "cbsa ~ '^([0-9]{5}|[0-9]{2})$'",
                         name: "corvid_zip_cbsa_crosswalks_cbsa_check"
  end
end
