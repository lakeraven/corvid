# CMS Critical Access Hospital registry. CMS pays CAHs at 101% of
# reasonable cost; for PRC MLR purposes the same 1.01× multiplier
# applies on top of the otherwise-computed Medicare-allowable rate.
# A facility is identified primarily by CCN (CMS Certification Number);
# NPI is captured when available since PRC exports may carry either.
class CreateCorvidCahFacilities < ActiveRecord::Migration[8.0]
  def change
    create_table :corvid_cah_facilities do |t|
      # Either ccn or npi must be present (model-level validation);
      # CMS feeds can be CCN-keyed, NPI-keyed, or both. A row with
      # only NPI is a legitimate match target for vendor_id lookup.
      t.string :ccn
      t.string :npi
      t.string :facility_name
      t.date :effective_date, null: false
      t.date :end_date
      t.string :source_release
      t.timestamps
    end

    # Partial unique on (ccn, effective_date) — only enforced when
    # ccn is present, so NPI-only rows aren't blocked. Symmetric
    # partial unique on (npi, effective_date) prevents overlapping
    # NPI-keyed rows from coexisting. Together they cover the
    # "historical periods coexist for the same identifier" intent
    # without forcing both identifiers to be supplied.
    add_index :corvid_cah_facilities, [ :ccn, :effective_date ], unique: true,
              where: "ccn IS NOT NULL",
              name: "idx_corvid_cah_ccn_effective"
    add_index :corvid_cah_facilities, [ :npi, :effective_date ], unique: true,
              where: "npi IS NOT NULL",
              name: "idx_corvid_cah_npi_effective"
  end
end
