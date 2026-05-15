# frozen_string_literal: true

module Corvid
  # NPI ↔ CCN crosswalk. CMS POS files (CAH, ASC registries) are keyed
  # by CCN; tribal PRC exports may key vendor_id by either CCN or NPI
  # depending on the EHR source. CahFacility#applies? and
  # AscFacility#applies? consult this table to resolve an NPI-keyed
  # vendor_id to the CCNs that NPI billed under on the service date.
  #
  # Sourced from CMS NPPES. Each row maps an NPI to a CCN for a
  # specific time window; an NPI may map to multiple CCNs over time
  # (organizational restructure, ownership change).
  class NpiCcnCrosswalk < ::ActiveRecord::Base
    self.table_name = "corvid_npi_ccn_crosswalks"

    validates :npi, presence: true
    validates :ccn, presence: true

    # Returns the distinct CCNs an NPI was billing under on the given
    # service date. Empty if the NPI has no crosswalk row in effect.
    #
    # When multiple labeled NPPES snapshots coexist, the latest snapshot
    # is authoritative — a refreshed snapshot may correct or remove a
    # mapping present in an older one, and stale rows must not route
    # claims. Rows with nil source_release (manual or pre-snapshot
    # loads) are treated as their own release.
    def self.ccns_for(npi:, on:)
      return [] if npi.blank? || on.nil?

      scope = where(npi: npi)
        .where("effective_date IS NULL OR effective_date <= ?", on)
        .where("end_date IS NULL OR end_date >= ?", on)

      latest = scope.maximum(:source_release)
      scope.where(source_release: latest).distinct.pluck(:ccn)
    end
  end
end
