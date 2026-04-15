# frozen_string_literal: true

class CreateCorvidEligibilityChecklists < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_eligibility_checklists do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :prc_referral, null: false, foreign_key: { to_table: :corvid_prc_referrals }

      # 1. Application (22/60 missing in FY23 audit)
      t.boolean :application_complete, default: false, null: false
      t.datetime :application_completed_at
      t.string :application_completed_by

      # 2. Identity documentation (40/60 missing)
      t.boolean :identity_verified, default: false, null: false
      t.datetime :identity_verified_at
      t.string :identity_verification_source

      # 3. Insurance / alternate resource (5/60 missing)
      t.boolean :insurance_verified, default: false, null: false
      t.datetime :insurance_verified_at
      t.string :insurance_verification_source

      # 4. Residency (15/60 missing)
      t.boolean :residency_verified, default: false, null: false
      t.datetime :residency_verified_at
      t.string :residency_verification_source

      # 5. Tribal enrollment (5/60 missing)
      t.boolean :enrollment_verified, default: false, null: false
      t.datetime :enrollment_verified_at
      t.string :enrollment_verification_source

      # 6. Clinical necessity (part of 41/60 catch-all)
      t.boolean :clinical_necessity_documented, default: false, null: false
      t.datetime :clinical_necessity_documented_at
      t.string :clinical_necessity_documentation_source

      # 7. Management approval (53/60 missing)
      t.boolean :management_approved, default: false, null: false
      t.datetime :management_approved_at
      t.string :management_approved_by

      t.timestamps
    end

    add_index :corvid_eligibility_checklists,
              [:tenant_identifier, :facility_identifier],
              name: "idx_corvid_elig_checklists_tenant_facility"
    add_index :corvid_eligibility_checklists,
              :prc_referral_id,
              unique: true,
              name: "idx_corvid_elig_checklists_referral_unique"
  end
end
