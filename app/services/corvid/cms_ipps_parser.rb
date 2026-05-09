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
      def parse_drg_weights(io_or_string, fiscal_year:)
        rows = read_csv(io_or_string, required_headers: DRG_HEADERS)
        rows.map do |row|
          {
            fiscal_year: fiscal_year,
            drg_code: row["drg_code"].to_s.strip,
            relative_weight: BigDecimal(row["relative_weight"].to_s)
          }
        end
      end

      def parse_hospital_rates(io_or_string, fiscal_year:)
        rows = read_csv(io_or_string, required_headers: HOSPITAL_HEADERS)
        rows.map do |row|
          {
            fiscal_year: fiscal_year,
            locality: row["locality"].to_s.strip,
            base_rate: BigDecimal(row["base_rate"].to_s),
            wage_index: BigDecimal(row["wage_index"].to_s)
          }
        end
      end

      private

      def read_csv(io_or_string, required_headers:)
        table = CSV.parse(io_or_string, headers: true)
        missing = required_headers - (table.headers || [])
        if missing.any?
          raise MalformedFileError,
                "missing required columns: #{missing.join(', ')}; got: #{table.headers.inspect}"
        end
        table
      end
    end
  end
end
