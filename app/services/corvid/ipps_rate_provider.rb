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

    # Result struct so callers can inspect the release_label and decide
    # confidence. The label travels alongside the rate so a stub-derived
    # row (release_label: "stub_v1") can be reported as :stub_estimate
    # rather than misrepresented as :clear.
    Lookup = Struct.new(:rate, :release_label, keyword_init: true)

    class << self
      def rate_for(drg_code:, locality: nil, date: nil)
        result = lookup_for(drg_code: drg_code, locality: locality, date: date)
        result&.rate
      end

      def lookup_for(drg_code:, locality: nil, date: nil)
        return nil if drg_code.nil? || date.nil?

        fy = federal_fiscal_year(date)
        weight_row = IppsDrgWeight.find_by(drg_code: drg_code.to_s, fiscal_year: fy)
        return nil unless weight_row

        hospital_rate = IppsHospitalRate.lookup(fiscal_year: fy, locality: locality)
        return nil unless hospital_rate

        rate = (weight_row.relative_weight * hospital_rate.base_rate * hospital_rate.wage_index).round(2)
        # Take the more conservative label between the two rows: if
        # either is stub-derived, the resulting rate is stub-derived.
        label = [ weight_row.release_label, hospital_rate.release_label ]
                  .compact.find { |l| l.to_s.start_with?("stub") } ||
                weight_row.release_label || hospital_rate.release_label
        Lookup.new(rate: rate, release_label: label)
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
