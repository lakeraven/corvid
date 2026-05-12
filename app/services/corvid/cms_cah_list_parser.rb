# frozen_string_literal: true

require "csv"

module Corvid
  # Parses a canonical CSV of CMS Critical Access Hospital records into
  # row hashes ready for upsert into corvid_cah_facilities. Expected
  # columns (header required): ccn, facility_name, effective_date,
  # npi (optional), end_date (optional). Comment lines starting with
  # "#" are skipped so the canonical file can carry a release_label
  # marker on its first line.
  module CmsCahListParser
    REQUIRED_COLUMNS = %w[ccn effective_date].freeze

    def self.parse(csv_text, release_label:)
      stripped = csv_text.lines.reject { |l| l.lstrip.start_with?("#") }.join
      table = CSV.parse(stripped, headers: true, skip_blanks: true)

      missing = REQUIRED_COLUMNS - table.headers
      raise ArgumentError, "CAH CSV missing required columns: #{missing.join(', ')}" if missing.any?

      table.map do |row|
        {
          ccn: row["ccn"]&.strip,
          npi: row["npi"]&.strip.presence,
          facility_name: row["facility_name"]&.strip.presence,
          effective_date: parse_date(row["effective_date"]),
          end_date: parse_date(row["end_date"]),
          source_release: release_label
        }
      end
    end

    def self.parse_date(value)
      return nil if value.nil? || value.strip.empty?
      Date.parse(value.strip)
    rescue ArgumentError
      nil
    end
  end
end
