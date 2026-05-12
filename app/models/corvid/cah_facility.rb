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
  class CahFacility < ::ActiveRecord::Base
    self.table_name = "corvid_cah_facilities"

    validates :ccn, presence: true
    validates :effective_date, presence: true
    validates :ccn, uniqueness: { scope: :effective_date }

    # Returns true iff a CAH row matches the given vendor identifier
    # (ccn or npi) and is in effect on the service date.
    def self.applies?(vendor_id:, on:)
      return false if vendor_id.blank? || on.nil?

      where("ccn = :v OR npi = :v", v: vendor_id)
        .where("effective_date <= ?", on)
        .where("end_date IS NULL OR end_date >= ?", on)
        .exists?
    end
  end
end
