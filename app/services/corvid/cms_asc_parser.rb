# frozen_string_literal: true

require "csv"
require "bigdecimal"

module Corvid
  # Parses the canonical CSV shape the ASC normalizers produce, with
  # strict numeric validation. Mirrors CmsOppsParser — same role,
  # ASC-specific column shapes.
  #
  # Two file shapes:
  #   HCPCS rates:         `hcpcs_code,payment_indicator,payment_weight`
  #   Conversion factors:  `locality,conversion_factor,wage_index`
  #
  # Strict numeric parsing (BigDecimal) raises MalformedFileError on
  # garbage like "abc" or "12O.34". This is the guardrail against
  # `to_f + insert_all` bypassing model validations — a malformed
  # weight or CF must surface during ingest, not become a silent 0.0
  # row that prices every HCPCS lookup at $0.
  module CmsAscParser
    HCPCS_HEADERS = %w[hcpcs_code payment_weight].freeze
    CF_HEADERS = %w[locality conversion_factor wage_index].freeze

    class MalformedFileError < StandardError; end

    class << self
      def parse_hcpcs_rates(io_or_string, calendar_year:, release_label: nil)
        rows = read_csv(io_or_string, required_headers: HCPCS_HEADERS)
        rows.filter_map do |row|
          code = row["hcpcs_code"].to_s.strip
          weight_raw = row["payment_weight"]
          next if code.empty? && weight_raw.to_s.strip.empty?
          {
            calendar_year: calendar_year,
            hcpcs_code: code,
            payment_indicator: row["payment_indicator"]&.strip.presence,
            payment_weight: parse_decimal(weight_raw, column: "payment_weight", row: row),
            release_label: release_label
          }
        end
      end

      def parse_conversion_factors(io_or_string, calendar_year:, release_label: nil)
        rows = read_csv(io_or_string, required_headers: CF_HEADERS)
        rows.filter_map do |row|
          locality = row["locality"].to_s.strip
          cf_raw = row["conversion_factor"]
          wage_raw = row["wage_index"]
          next if locality.empty? && cf_raw.to_s.strip.empty? && wage_raw.to_s.strip.empty?
          {
            calendar_year: calendar_year,
            locality: locality,
            conversion_factor: parse_decimal(cf_raw, column: "conversion_factor", row: row),
            wage_index: parse_decimal(wage_raw, column: "wage_index", row: row),
            release_label: release_label
          }
        end
      end

      private

      def read_csv(io_or_string, required_headers:)
        text = io_or_string.respond_to?(:read) ? io_or_string.read : io_or_string.to_s
        stripped = text.sub(/\A\xEF\xBB\xBF/, "")
                       .lines.reject { |l| l.lstrip.start_with?("#") }.join
        table = CSV.parse(stripped, headers: true)
        missing = required_headers - (table.headers || []).map { |h| h.to_s.strip }
        if missing.any?
          raise MalformedFileError,
                "missing required columns: #{missing.join(', ')}; got: #{table.headers.inspect}"
        end
        table
      end

      def parse_decimal(raw, column:, row:)
        cleaned = raw.to_s.strip.delete(",").sub(/\A\$/, "")
        BigDecimal(cleaned)
      rescue ArgumentError, TypeError => e
        raise MalformedFileError,
              "could not parse #{column}=#{raw.inspect} as decimal in row #{row.to_h.inspect}: #{e.message}"
      end
    end
  end
end
