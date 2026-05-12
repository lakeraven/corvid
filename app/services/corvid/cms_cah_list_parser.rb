# frozen_string_literal: true

require "csv"

module Corvid
  # Parses a canonical CSV of CMS Critical Access Hospital records into
  # row hashes ready for upsert into corvid_cah_facilities. Expected
  # columns (header required): ccn, facility_name, effective_date,
  # npi (optional), end_date (optional). Comment lines starting with
  # "#" are skipped so the canonical file can carry a release_label
  # marker on its first line.
  #
  # Returns `{ rows: [...], rejects: [{row_number:, reason:, raw:}] }`.
  # Per-row validation drops (not raises) on blank ccn or missing/
  # malformed effective_date — consistent with PrcImporter's permissive-
  # but-report pattern. Caller (rake task) decides what to do with rejects.
  module CmsCahListParser
    REQUIRED_COLUMNS = %w[ccn effective_date].freeze

    def self.parse(csv_text, release_label:)
      stripped = csv_text.lines.reject { |l| l.lstrip.start_with?("#") }.join
      table = CSV.parse(stripped, headers: true, skip_blanks: true)

      missing = REQUIRED_COLUMNS - table.headers
      raise ArgumentError, "CAH CSV missing required columns: #{missing.join(', ')}" if missing.any?

      rows = []
      rejects = []
      table.each_with_index do |row, idx|
        row_number = idx + 2 # +1 for 0-indexed, +1 for the header line
        ccn = row["ccn"]&.strip
        effective_date = parse_date(row["effective_date"])

        if ccn.nil? || ccn.empty?
          rejects << { row_number: row_number, reason: "blank ccn", raw: row.to_h }
          next
        end
        if effective_date.nil?
          rejects << {
            row_number: row_number,
            reason: "missing or malformed effective_date (#{row['effective_date'].inspect})",
            raw: row.to_h
          }
          next
        end

        rows << {
          ccn: ccn,
          npi: row["npi"]&.strip.presence,
          facility_name: row["facility_name"]&.strip.presence,
          effective_date: effective_date,
          end_date: parse_date(row["end_date"]),
          source_release: release_label
        }
      end

      { rows: rows, rejects: rejects }
    end

    def self.parse_date(value)
      return nil if value.nil? || value.strip.empty?
      Date.parse(value.strip)
    rescue ArgumentError
      nil
    end
  end
end
