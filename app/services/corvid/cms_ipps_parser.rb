# frozen_string_literal: true

require "csv"

module Corvid
  # Parses the canonical CSV shape we normalize CMS IPPS Final Rule
  # tables into before importing. CMS publishes these as XLSX with
  # year-shifting layouts; the data-acquisition follow-up PR wraps
  # XLSX → canonical-CSV conversion. This parser handles only the
  # canonical CSV (so unit tests don't depend on Excel libraries).
  #
  # Two file shapes:
  #   DRG weights:   `drg_code,relative_weight`
  #   Hospital:      `locality,base_rate,wage_index`
  #
  # Both stamp `fiscal_year` from the caller — CMS files are FY-
  # specific by filename, not by an in-row column.
  module CmsIppsParser
    DRG_HEADERS = %w[drg_code relative_weight].freeze
    HOSPITAL_HEADERS = %w[locality base_rate wage_index].freeze

    class MalformedFileError < StandardError; end

    class << self
      def parse_drg_weights(io_or_string, fiscal_year:, release_label: nil)
        rows = read_csv(io_or_string, required_headers: DRG_HEADERS)
        rows.filter_map do |row|
          drg_code = row["drg_code"].to_s.strip
          weight_raw = row["relative_weight"]
          next if drg_code.empty? && weight_raw.to_s.strip.empty? # skip blank lines
          {
            fiscal_year: fiscal_year,
            drg_code: drg_code,
            relative_weight: parse_decimal(weight_raw, column: "relative_weight", row: row),
            release_label: release_label
          }
        end
      end

      def parse_hospital_rates(io_or_string, fiscal_year:, release_label: nil)
        rows = read_csv(io_or_string, required_headers: HOSPITAL_HEADERS)
        rows.filter_map do |row|
          locality = row["locality"].to_s.strip
          base_raw = row["base_rate"]
          wage_raw = row["wage_index"]
          next if locality.empty? && base_raw.to_s.strip.empty? && wage_raw.to_s.strip.empty?
          {
            fiscal_year: fiscal_year,
            locality: locality,
            base_rate: parse_decimal(base_raw, column: "base_rate", row: row),
            wage_index: parse_decimal(wage_raw, column: "wage_index", row: row),
            release_label: release_label
          }
        end
      end

      private

      def read_csv(io_or_string, required_headers:)
        # `bom: true` strips a leading UTF-8 BOM so the first header
        # name doesn't get an invisible ﻿ prefix that would fail
        # the required-headers check on otherwise-valid files.
        text = io_or_string.respond_to?(:read) ? io_or_string.read : io_or_string.to_s
        table = CSV.parse(text.sub(/\A\xEF\xBB\xBF/, ""), headers: true)
        missing = required_headers - (table.headers || []).map { |h| h.to_s.strip }
        if missing.any?
          raise MalformedFileError,
                "missing required columns: #{missing.join(', ')}; got: #{table.headers.inspect}"
        end
        table
      end

      # Tolerate common canonical-CSV artifacts: stripped whitespace,
      # thousands-separator commas in numeric strings, currency-symbol
      # prefixes. Anything that genuinely doesn't parse raises a clear
      # MalformedFileError pinpointing the row and column.
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
