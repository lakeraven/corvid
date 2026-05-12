# frozen_string_literal: true

module Corvid
  # Real ASC APC rate provider (#278). Same shape as OppsRateProvider:
  #
  #   medicare_equivalent = apc_relative_weight × conversion_factor × wage_index
  #
  # Different tables: corvid_asc_apc_weights and corvid_asc_conversion_
  # factors carry ASC-specific values (CMS Addendum AA + ASC CF). For
  # an APC that's both OPPS-paid and ASC-paid, the ASC rate is usually
  # lower than OPPS (lower CF, sometimes lower weight).
  #
  # Calendar-year boundaries (Jan 1), matching OPPS.
  module AscRateProvider
    SOURCE = :asc_real

    Lookup = Struct.new(:rate, :release_label, keyword_init: true)

    class << self
      def rate_for(apc_code:, locality: nil, date: nil)
        result = lookup_for(apc_code: apc_code, locality: locality, date: date)
        result&.rate
      end

      def lookup_for(apc_code:, locality: nil, date: nil)
        return nil if apc_code.nil? || date.nil?

        normalized_locality = locality.to_s.strip.empty? ? AscConversionFactor::NATIONAL_LOCALITY : locality

        cy = calendar_year(date)
        weight_row = AscApcWeight.find_by(apc_code: apc_code.to_s, calendar_year: cy)
        return nil unless weight_row

        cf_row = AscConversionFactor.lookup(calendar_year: cy, locality: normalized_locality)
        return nil unless cf_row

        rate = (weight_row.relative_weight * cf_row.conversion_factor * cf_row.wage_index).round(2)
        label = [ weight_row.release_label, cf_row.release_label ]
                  .compact.find { |l| l.to_s.start_with?("stub") } ||
                weight_row.release_label || cf_row.release_label
        Lookup.new(rate: rate, release_label: label)
      end

      def source
        SOURCE
      end

      private

      def calendar_year(date)
        date.respond_to?(:year) ? date.year : date.to_i
      end
    end
  end
end
