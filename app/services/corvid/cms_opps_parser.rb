# frozen_string_literal: true

require "csv"

module Corvid
  # Parses the canonical CSV shape we normalize CMS OPPS Final Rule
  # tables into. Mirrors CmsIppsParser; OPPS uses calendar-year-keyed
  # data (not federal fiscal year).
  #
  # Two file shapes:
  #   APC weights:         `apc_code,relative_weight[,description]`
  #   Conversion factors:  `locality,conversion_factor,wage_index`
  module CmsOppsParser
    APC_HEADERS = %w[apc_code relative_weight].freeze
    CF_HEADERS = %w[locality conversion_factor wage_index].freeze

    class MalformedFileError < StandardError; end

    class << self
      def parse_apc_weights(io_or_string, calendar_year:, release_label: nil)
        rows = read_csv(io_or_string, required_headers: APC_HEADERS)
        rows.filter_map do |row|
          code = row["apc_code"].to_s.strip
          weight_raw = row["relative_weight"]
          next if code.empty? && weight_raw.to_s.strip.empty?
          {
            calendar_year: calendar_year,
            apc_code: code,
            relative_weight: parse_decimal(weight_raw, column: "relative_weight", row: row),
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
        # Strip BOM + comment lines. Canonical files carry a
        # `# release_label: ...` marker on the first line; older callers
        # (cms:opps:import_*) read raw, so the parser handles it unconditionally.
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
