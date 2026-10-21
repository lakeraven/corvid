# frozen_string_literal: true

module Corvid
  # Id segment of a FHIR reference.
  #
  # Accepts "Type/id" and "Type/id/_history/version". When +base_url+ is
  # given, accepts only that server's absolute form of those shapes (the
  # base URL may have a trailing slash). After ASCII whitespace is stripped,
  # the id must match FHIR id syntax plus underscore. +type+ is a resource
  # name or a list of names. nil, blank, a non-String, a missing or invalid
  # id, a contained reference, extra path segments, a foreign absolute URL,
  # a different type, and a string with invalid encoding are nil. Never
  # raises, and never returns the raw reference.
  module FhirReference
    RESOURCE_TYPE = /\A[A-Z][A-Za-z0-9]*\z/
    ID_SYNTAX = /\A[A-Za-z0-9._-]{1,64}\z/
    PROVIDER_TYPES = %w[Practitioner PractitionerRole Organization].freeze

    class << self
      def id_from(ref, type: nil, base_url: nil)
        relative = relative_reference(ref, base_url)
        return nil unless relative

        segments = relative.split("/", -1)
        return nil unless type_allowed?(segments[0], type)

        identifier(segments)
      end

      private

      def relative_reference(ref, base_url)
        return nil unless ref.is_a?(String) && ref.valid_encoding?
        return ref if base_url.nil?

        strip_base_url(ref, base_url)
      end

      def strip_base_url(ref, base_url)
        return nil unless base_url.is_a?(String) && base_url.valid_encoding?

        prefix = "#{base_url.chomp("/")}/"
        return nil unless ref.start_with?(prefix)

        ref.delete_prefix(prefix)
      end

      def type_allowed?(resource_type, type)
        return false unless resource_type.is_a?(String) && resource_type.match?(RESOURCE_TYPE)
        return true if type.nil?
        return resource_type == type if type.is_a?(String)
        return type.include?(resource_type) if type.is_a?(Array)

        false
      end

      def identifier(segments)
        raw = id_segment(segments)
        return nil unless raw

        id = ascii_strip(raw)
        id if id.match?(ID_SYNTAX)
      end

      def id_segment(segments)
        case segments.length
        when 2
          segments[1]
        when 4
          return unless segments[2] == "_history"
          return if ascii_strip(segments[3]).empty?

          segments[1]
        end
      end

      def ascii_strip(value)
        value.sub(/\A[ \t\n\v\f\r]+/, "").sub(/[ \t\n\v\f\r]+\z/, "")
      end
    end
  end
end
