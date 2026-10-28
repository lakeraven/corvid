# frozen_string_literal: true

module Corvid
  # Maps RPMS PRC facility codes (e.g., "SEA") to ZIP and Medicare locality
  # so PrcOverpaymentAnalyzer can apply the correct GPCI/wage-index adjustments.
  #
  # Hosts can register custom mappings from an initializer to cover their
  # local PRC facility codes.
  #
  # `.crosswalk_for` loads the ZipCbsaCrosswalk row for a facility ZIP
  # in the federal fiscal year of the service date, one indexed query
  # per call. `.cbsa_for` returns that row's wage area. With no row for
  # that fiscal year either method returns nil, and institutional
  # pricing stays on the NATIONAL wage index. `.normalized_zip` and
  # `.fiscal_year_for` are the shared ZIP and fiscal-year rules.
  module PrcFacilityDictionary
    Entry = Struct.new(:code, :name, :city, :state, :zip, :locality, keyword_init: true)

    DEFAULTS = [
      # CMS locality 02 = Seattle metro (King, Pierce, Snohomish counties).
      { code: "SEA", name: "Seattle service area", city: "Seattle", state: "WA", zip: "98101", locality: "02" },
      # CMS locality 99 = Washington (rest of state).
      { code: "YAK", name: "Yakima service area", city: "Yakima",  state: "WA", zip: "98901", locality: "99" },
      { code: "OTH", name: "Other WA service area", city: "Other WA", state: "WA", zip: "99201", locality: "99" }
    ].freeze

    class << self
      def register(code, name: nil, city: nil, state: nil, zip: nil, locality: nil)
        ensure_loaded
        @entries[code.to_s] = Entry.new(
          code: code.to_s, name: name, city: city, state: state, zip: zip, locality: locality
        )
      end

      def lookup(code)
        ensure_loaded
        @entries[code.to_s]
      end

      def codes
        ensure_loaded
        @entries.keys
      end

      def reset!
        @entries = nil
        @loaded = false
        ensure_loaded
      end

      # ZipCbsaCrosswalk row for a facility ZIP in the federal fiscal
      # year of `on` (FY starts October 1; omitted `on` is Date.current).
      # Accepts "#####" or "#####-####". Anything else, or a year with
      # no row, returns nil. Each call is one indexed query; nothing
      # is cached.
      def crosswalk_for(zip:, on: nil)
        normalized = normalized_zip(zip)
        return if normalized.nil?

        ZipCbsaCrosswalk.find_by(
          fiscal_year: fiscal_year_for(service_date(on)),
          zip: normalized
        )
      end

      # CMS wage area for a facility ZIP. Same ZIP and fiscal-year rules
      # as crosswalk_for; the wage area is that row's cbsa.
      def cbsa_for(zip:, on: nil)
        crosswalk_for(zip: zip, on: on)&.cbsa
      end

      # Five-digit ZIP when `zip` is "#####" or "#####-####"; otherwise
      # nil. Non-strings (nil, integers) are nil. Does not query.
      def normalized_zip(zip)
        return unless zip.is_a?(String) && zip.match?(/\A[0-9]{5}(?:-[0-9]{4})?\z/)

        zip[0, 5]
      end

      # Federal fiscal year of a Date. October 1 starts the next FY.
      def fiscal_year_for(date)
        date.month >= 10 ? date.year + 1 : date.year
      end

      private

      def service_date(on)
        return Date.current if on.nil?
        return on if on.is_a?(Date)

        raise ArgumentError, "on must be a Date"
      end

      def ensure_loaded
        return if @loaded

        @entries = {}
        DEFAULTS.each do |attrs|
          @entries[attrs[:code]] = Entry.new(**attrs)
        end
        @loaded = true
      end
    end
  end
end
