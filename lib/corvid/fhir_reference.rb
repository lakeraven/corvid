# frozen_string_literal: true

module Corvid
  # Id segment of a FHIR reference.
  #
  # Accepts "Type/id" and "Type/id/_history/version". When +base_url+ is
  # given, accepts only that server's absolute form of those shapes (the
  # base URL may have a trailing slash). After ASCII whitespace is stripped,
  # the id must match FHIR id syntax or a Corvid reference token
  # (CORVID_TOKEN). The _history version stays strict FHIR id syntax, with
  # no underscore. +type+ is a resource name or a list of names. nil, blank,
  # a non-String, a missing or invalid id, a contained reference, extra path
  # segments, a foreign absolute URL, a different type, and a string with
  # invalid encoding are nil. A reference whose encoding is not
  # ASCII-compatible is read as UTF-8 when the bytes transcode, and is nil
  # when they do not. A base_url that is not ASCII-compatible is nil. A
  # reference and base_url that cannot be compared (Windows-1252 or BINARY
  # high bytes against non-ASCII UTF-8, or the reverse) are nil. Those
  # ASCII-compatible strings are not transcoded into a match. Never raises,
  # never coerces a non-String, and never returns the raw reference.
  module FhirReference
    RESOURCE_TYPE = /\A[A-Z][A-Za-z0-9]*\z/
    ID_SYNTAX = /\A[A-Za-z0-9\-\.]{1,64}\z/
    # Vault tokens that appear in references (ADR 0001, ADR 0003).
    # MockAdapter#dereference resolves pt_, pr_, and rf_. store_text
    # prefixes are text tokens and never appear in references, so they are
    # not an exception. One underscore, then FHIR id characters, 64
    # characters total. The _history version stays ID_SYNTAX.
    CORVID_TOKEN_PREFIXES = %w[pt pr rf].freeze
    CORVID_TOKEN = /\A(?:#{CORVID_TOKEN_PREFIXES.join("|")})_[A-Za-z0-9\-\.]{1,61}\z/
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
        compatible = compatible_reference(ref)
        return nil unless compatible
        return compatible if base_url.nil?

        strip_base_url(compatible, base_url)
      end

      # Valid ASCII-compatible text is used as-is. Any other valid encoding
      # (UTF-16, UTF-32) is transcoded to UTF-8 so the id can be read.
      # Invalid bytes and a failed transcode are nil.
      def compatible_reference(ref)
        return nil unless ref.is_a?(String) && ref.valid_encoding?
        return ref if ref.encoding.ascii_compatible?

        ref.encode(Encoding::UTF_8)
      rescue EncodingError
        nil
      end

      def strip_base_url(ref, base_url)
        return nil unless compatible_base_url?(base_url)
        return nil unless Encoding.compatible?(ref, base_url)

        prefix = "#{base_url.chomp("/")}/"
        return nil unless ref.start_with?(prefix)

        ref.delete_prefix(prefix)
      rescue EncodingError
        nil
      end

      def compatible_base_url?(base_url)
        base_url.is_a?(String) && base_url.valid_encoding? && base_url.encoding.ascii_compatible?
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
        id if id.match?(ID_SYNTAX) || id.match?(CORVID_TOKEN)
      end

      def id_segment(segments)
        case segments.length
        when 2
          segments[1]
        when 4
          segments[1] if history_version?(segments)
        end
      end

      def history_version?(segments)
        segments[2] == "_history" && ascii_strip(segments[3]).match?(ID_SYNTAX)
      end

      def ascii_strip(value)
        value.sub(/\A[ \t\n\v\f\r]+/, "").sub(/[ \t\n\v\f\r]+\z/, "")
      end
    end
  end
end
