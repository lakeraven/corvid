# frozen_string_literal: true

module Corvid
  # Id segment of a FHIR relative reference.
  #
  # Accepts only "Type/id" and "Type/id/_history/version". Returns the
  # stripped id. nil, blank, a non-String, a missing or whitespace id, an
  # absolute URL, a contained ("#...") reference, extra path segments, and
  # (when +type:+ is given) a different Type are nil. Never raises, and
  # never returns the raw reference.
  module FhirReference
    RESOURCE_TYPE = /\A[A-Z][A-Za-z0-9]*\z/

    class << self
      def id_from(ref, type: nil)
        return nil unless ref.is_a?(String)

        segments = ref.split("/", -1)
        resource_type = segments[0]
        return nil unless resource_type.is_a?(String) && resource_type.match?(RESOURCE_TYPE)
        return nil if type && resource_type != type

        id_segment(segments)&.strip.presence
      end

      private

      def id_segment(segments)
        case segments.length
        when 2
          segments[1]
        when 4
          return unless segments[2] == "_history"
          return if segments[3].strip.empty?

          segments[1]
        end
      end
    end
  end
end
