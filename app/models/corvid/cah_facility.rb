# frozen_string_literal: true

module Corvid
  # CMS Critical Access Hospital registry. A vendor whose ccn or npi
  # matches an active row here is paid at 101% of the otherwise-
  # computed Medicare-allowable rate (CMS pays CAHs at 101% of
  # reasonable cost). The 1.01× multiplier wraps PFS/IPPS/OPPS rates
  # at the analyzer boundary; the underlying rate row's release_label
  # still flows to provenance.
  #
  # The list is sourced from CMS and refreshed periodically. Rows
  # carry effective_date and (optionally) end_date so historical
  # claims reprice against the CAH status that applied on the service
  # date, not the current status.
  #
  # Either ccn or npi must be present — CMS feeds can be keyed by
  # either, and a row with only NPI is a legitimate match target.
  class CahFacility < ::ActiveRecord::Base
    self.table_name = "corvid_cah_facilities"

    validates :effective_date, presence: true
    validate :ccn_or_npi_present
    validates :ccn, uniqueness: { scope: :effective_date }, allow_nil: true
    validates :npi, uniqueness: { scope: :effective_date }, allow_nil: true

    # Returns true iff a CAH row matches the given vendor identifier
    # (ccn or npi) and is in effect on the service date. When the vendor
    # is keyed by NPI but CMS only lists the facility by CCN, the
    # NPI↔CCN crosswalk resolves the NPI to its CCN(s) in effect on the
    # service date.
    def self.applies?(vendor_id:, on:)
      return false if vendor_id.blank? || on.nil?

      candidates = [ vendor_id ] + NpiCcnCrosswalk.ccns_for(npi: vendor_id, on: on)
      where("ccn IN (:v) OR npi IN (:v)", v: candidates)
        .where("effective_date <= ?", on)
        .where("end_date IS NULL OR end_date >= ?", on)
        .exists?
    end

    private

    def ccn_or_npi_present
      return if ccn.present? || npi.present?
      errors.add(:base, "must have at least one of ccn or npi")
    end
  end
end
