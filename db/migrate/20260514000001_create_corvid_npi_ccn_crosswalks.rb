# frozen_string_literal: true

# NPI ↔ CCN crosswalk table. The CMS Provider of Services (POS) files
# we use for CAH and ASC facility registries don't carry NPI. Tribal
# PRC exports may carry vendor_id as either CCN or NPI depending on
# the EHR source. Without this crosswalk, CahFacility#applies? and
# AscFacility#applies? silently miss every NPI-keyed vendor_id and
# the CAH multiplier / ASC routing never fire.
#
# Sourced from CMS NPPES (National Plan and Provider Enumeration
# System); each row maps an NPI to its CMS Other Provider Identifier
# (the CCN) for a specific time window.
class CreateCorvidNpiCcnCrosswalks < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_npi_ccn_crosswalks do |t|
      t.string :npi, null: false
      t.string :ccn, null: false
      t.date :effective_date
      t.date :end_date
      t.string :source_release
      t.timestamps
    end

    # Composite unique on (npi, ccn, effective_date) lets the same
    # NPI map to multiple CCNs over time (organizational restructure,
    # ownership change) and lets the same (npi, ccn) tuple have
    # multiple historical periods.
    add_index :corvid_npi_ccn_crosswalks, [ :npi, :ccn, :effective_date ],
              unique: true, name: "idx_corvid_npi_ccn_crosswalks_unique"

    # Hot-path lookups in applies?: given an NPI vendor_id, return CCNs.
    add_index :corvid_npi_ccn_crosswalks, :npi
    add_index :corvid_npi_ccn_crosswalks, :ccn
  end
end
