# frozen_string_literal: true

class CreateCorvidPrcObligations < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_prc_obligations do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier, null: false
      t.string :obligation_id, null: false
      t.string :patient_dfn
      t.string :vendor_id
      t.string :procedure_code
      t.date :service_date
      t.string :status
      t.decimal :billed_amount, precision: 12, scale: 2
      t.decimal :paid_amount, precision: 12, scale: 2
      t.decimal :savings, precision: 12, scale: 2
      t.decimal :balance, precision: 12, scale: 2
      t.integer :fiscal_year
      t.string :source_file
      t.datetime :imported_at, null: false

      t.timestamps
    end

    add_index :corvid_prc_obligations,
              [ :tenant_identifier, :obligation_id ],
              unique: true,
              name: "idx_corvid_prc_obligations_tenant_oblig"
    add_index :corvid_prc_obligations, [ :tenant_identifier, :service_date ]
    add_index :corvid_prc_obligations, [ :tenant_identifier, :vendor_id ]
    add_index :corvid_prc_obligations, [ :tenant_identifier, :fiscal_year ]

    create_table :corvid_prc_payments do |t|
      t.references :prc_obligation,
                   null: false,
                   foreign_key: { to_table: :corvid_prc_obligations },
                   index: { name: "idx_corvid_prc_payments_oblig" }
      t.string :tenant_identifier, null: false
      t.string :payment_id, null: false
      t.date :paid_date
      t.string :check_number
      t.decimal :amount, precision: 12, scale: 2
      t.string :vendor_name

      t.timestamps
    end

    add_index :corvid_prc_payments,
              [ :tenant_identifier, :payment_id ],
              unique: true,
              name: "idx_corvid_prc_payments_tenant_pmt"

    create_table :corvid_prc_overpayment_analyses do |t|
      t.references :prc_obligation,
                   null: false,
                   foreign_key: { to_table: :corvid_prc_obligations },
                   index: { name: "idx_corvid_prc_overpay_oblig" }
      t.string :tenant_identifier, null: false
      t.string :analyzer_version, null: false
      t.string :rate_source_release
      t.string :payment_system
      t.string :rate_source
      t.string :recovery_confidence, null: false
      t.decimal :medicare_equivalent, precision: 12, scale: 2
      t.decimal :overpayment, precision: 12, scale: 2
      t.text :notes
      t.datetime :analyzed_at, null: false

      t.timestamps
    end

    add_index :corvid_prc_overpayment_analyses,
              [ :tenant_identifier, :recovery_confidence ],
              name: "idx_corvid_prc_overpay_confidence"
    add_index :corvid_prc_overpayment_analyses,
              [ :prc_obligation_id, :analyzed_at ],
              name: "idx_corvid_prc_overpay_oblig_time"
  end
end
