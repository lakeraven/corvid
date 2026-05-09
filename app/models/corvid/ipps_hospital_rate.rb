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

    def self.lookup(fiscal_year:, locality:)
      find_by(fiscal_year: fiscal_year, locality: locality) ||
        find_by(fiscal_year: fiscal_year, locality: NATIONAL_LOCALITY)
    end
  end
end
