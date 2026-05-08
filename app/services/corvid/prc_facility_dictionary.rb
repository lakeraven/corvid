# frozen_string_literal: true

module Corvid
  # Maps RPMS PRC facility codes (e.g., "SEA") to ZIP and Medicare locality
  # so MlrRepricingService can apply the correct GPCI/wage-index adjustments.
  #
  # Hosts can register custom mappings from an initializer to cover their
  # local PRC facility codes.
  module PrcFacilityDictionary
    Entry = Struct.new(:code, :name, :city, :state, :zip, :locality, keyword_init: true)

    DEFAULTS = [
      # CMS locality 02 = Seattle metro (King, Pierce, Snohomish counties).
      { code: "SEA", name: "Seattle service area", city: "Seattle", state: "WA", zip: "98101", locality: "02" },
      # CMS locality 99 = Washington (rest of state).
      { code: "YAK", name: "Yakima service area", city: "Yakima",  state: "WA", zip: "98901", locality: "99" },
      { code: "SPK", name: "Spokane service area", city: "Spokane", state: "WA", zip: "99201", locality: "99" }
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

      private

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
