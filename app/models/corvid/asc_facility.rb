# frozen_string_literal: true

module Corvid
  # CMS Ambulatory Surgical Center registry. A vendor whose ccn or npi
  # matches an active row here is routed through AscRateProvider instead
  # of OppsRateProvider for outpatient claims — same APC code, different
  # (typically lower) Medicare-allowable rate.
  #
  # Sourced from CMS and refreshed periodically. Rows carry effective_date
  # and end_date so historical claims reprice against the ASC status that
  # applied on the service date, not the current status. Mirrors
  # CahFacility's temporal model.
  class AscFacility < ::ActiveRecord::Base
    self.table_name = "corvid_asc_facilities"

    validates :ccn, presence: true
    validates :effective_date, presence: true
    validates :ccn, uniqueness: { scope: :effective_date }

    def self.applies?(vendor_id:, on:)
      return false if vendor_id.blank? || on.nil?

      where("ccn = :v OR npi = :v", v: vendor_id)
        .where("effective_date <= ?", on)
        .where("end_date IS NULL OR end_date >= ?", on)
        .exists?
    end
  end
end
