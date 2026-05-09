# frozen_string_literal: true

module Corvid
  # Real IPPS DRG rate provider (#276). Returns the IPPS payment
  # estimate for a single discharge:
  #
  #   medicare_equivalent = drg_relative_weight × base_rate × wage_index
  #
  # Sourced from CMS IPPS Final Rule tables loaded into
  # corvid_ipps_drg_weights and corvid_ipps_hospital_rates. When data
  # for the (year, DRG, locality) tuple is missing, returns nil — the
  # analyzer falls back to IppsStubRateProvider in that case so an
  # obligation still gets a directional dollar figure at :stub_estimate
  # confidence.
  module IppsRateProvider
    # Symbol to match the contract used by IppsStubRateProvider#source
    # and the analyzer's public Result#rate_source. The string form
    # the data-acquisition pipeline cares about ("ipps_real") lives
    # in the analyzer's notes/provenance instead.
    SOURCE = :ipps_real

    class << self
      def rate_for(drg_code:, locality: nil, date: nil)
        return nil if drg_code.nil? || date.nil?

        fy = federal_fiscal_year(date)
        weight = IppsDrgWeight.weight_for(drg_code: drg_code, fiscal_year: fy)
        return nil unless weight

        hospital_rate = IppsHospitalRate.lookup(fiscal_year: fy, locality: locality)
        return nil unless hospital_rate

        (weight * hospital_rate.base_rate * hospital_rate.wage_index).round(2)
      end

      def source
        SOURCE
      end

      private

      # IPPS rates change Oct 1, not Jan 1. A Nov 15 2025 discharge
      # bills against FY 2026 rates.
      def federal_fiscal_year(date)
        date.month >= 10 ? date.year + 1 : date.year
      end
    end
  end
end
