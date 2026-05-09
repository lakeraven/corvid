# frozen_string_literal: true

module Corvid
  # CMS IPPS hospital base rate and wage index, by federal fiscal year
  # and locality. Locality "NATIONAL" is the fallback row used when no
  # locality-specific rate is loaded.
  class IppsHospitalRate < ::ActiveRecord::Base
    self.table_name = "corvid_ipps_hospital_rates"

    NATIONAL_LOCALITY = "NATIONAL"

    validates :fiscal_year, presence: true
    validates :locality, presence: true
    validates :base_rate, presence: true, numericality: { greater_than: 0 }
    validates :wage_index, presence: true, numericality: { greater_than: 0 }

    # Single query: load both the locality-specific row and the
    # NATIONAL fallback in one round trip, then prefer the specific
    # row when both exist. This is on the hot path for IPPS repricing
    # so the second SELECT-roundtrip the previous form did adds up.
    def self.lookup(fiscal_year:, locality:)
      rows = where(fiscal_year: fiscal_year, locality: [ locality, NATIONAL_LOCALITY ])
               .index_by(&:locality)
      rows[locality] || rows[NATIONAL_LOCALITY]
    end
  end
end
