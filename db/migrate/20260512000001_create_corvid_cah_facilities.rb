# CMS Critical Access Hospital registry. CMS pays CAHs at 101% of
# reasonable cost; for PRC MLR purposes the same 1.01× multiplier
# applies on top of the otherwise-computed Medicare-allowable rate.
# A facility is identified primarily by CCN (CMS Certification Number);
# NPI is captured when available since PRC exports may carry either.
class CreateCorvidCahFacilities < ActiveRecord::Migration[8.0]
  def change
    create_table :corvid_cah_facilities do |t|
      t.string :ccn, null: false
      t.string :npi
      t.string :facility_name
      t.date :effective_date, null: false
      t.date :end_date
      t.string :source_release
      t.timestamps
    end

    add_index :corvid_cah_facilities, :ccn, unique: true
    add_index :corvid_cah_facilities, :npi
  end
end
