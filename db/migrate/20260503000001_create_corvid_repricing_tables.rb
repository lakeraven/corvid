class CreateCorvidRepricingTables < ActiveRecord::Migration[8.0]
  def change
    create_table :corvid_fee_schedule_entries do |t|
      t.string :cpt_code, null: false
      t.string :locality, null: false
      t.date :effective_date, null: false
      t.decimal :work_rvu, precision: 8, scale: 4
      t.decimal :pe_rvu, precision: 8, scale: 4
      t.decimal :mp_rvu, precision: 8, scale: 4
      t.decimal :conversion_factor, precision: 8, scale: 4
      t.decimal :work_gpci, precision: 8, scale: 4
      t.decimal :pe_gpci, precision: 8, scale: 4
      t.decimal :mp_gpci, precision: 8, scale: 4
      t.string :description
      t.timestamps
    end

    add_index :corvid_fee_schedule_entries, [:cpt_code, :locality, :effective_date],
      unique: true, name: "idx_corvid_fee_schedule_unique"
    add_index :corvid_fee_schedule_entries, :cpt_code
    add_index :corvid_fee_schedule_entries, :effective_date

    create_table :corvid_zip_localities do |t|
      t.string :zip_code, null: false
      t.string :locality, null: false
      t.string :state
      t.string :locality_name
      t.timestamps
    end

    add_index :corvid_zip_localities, :zip_code, unique: true
    add_index :corvid_zip_localities, :locality
  end
end
