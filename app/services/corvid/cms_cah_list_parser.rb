# frozen_string_literal: true

require "csv"

module Corvid
  # Parses a canonical CSV of CMS Critical Access Hospital records into
  # row hashes ready for upsert into corvid_cah_facilities. Expected
  # columns (header required): ccn, facility_name, effective_date,
  # npi (optional), end_date (optional). Comment lines starting with
  # "#" are skipped so the canonical file can carry a release_label
  # marker on its first line. Headers are case-insensitive and a UTF-8
  # BOM at the start of the file is stripped (common from spreadsheets).
  #
  # Returns `{ rows: [...], rejects: [{row_number:, reason:, raw:}] }`.
  # Per-row validation drops (not raises) on blank ccn or missing/
  # malformed effective_date — consistent with PrcImporter's permissive-
  # but-report pattern. `row_number` references the original file's
  # line number, including any skipped comment lines, so ops can locate
  # the offending row directly in the source.
  module CmsCahListParser
    # Only effective_date is structurally required at the column level —
    # a CMS feed may be CCN-keyed, NPI-keyed, or both. Per-row validation
    # below rejects rows where neither identifier is present.
    REQUIRED_COLUMNS = %w[effective_date].freeze
    BOM = "﻿"

    def self.parse(csv_text, release_label:)
      text = csv_text.delete_prefix(BOM)

      # Strip comment + blank lines but preserve original line numbers
      # for each data row so reject reports cite the right source line.
      kept_lines = []
      data_line_numbers = []
      header_seen = false
      text.each_line.with_index(1) do |line, lineno|
        next if line.lstrip.start_with?("#") || line.strip.empty?
        kept_lines << line
        if header_seen
          data_line_numbers << lineno
        else
          header_seen = true
        end
      end

      table = CSV.parse(
        kept_lines.join, headers: true, skip_blanks: true,
        header_converters: ->(h) { h&.strip&.downcase }
      )

      missing = REQUIRED_COLUMNS - table.headers
      raise ArgumentError, "CAH CSV missing required columns: #{missing.join(', ')}" if missing.any?

      rows = []
      rejects = []
      table.each_with_index do |row, idx|
        row_number = data_line_numbers[idx]
        ccn = row["ccn"]&.strip.presence
        npi = row["npi"]&.strip.presence
        effective_date = parse_date(row["effective_date"])

        if ccn.nil? && npi.nil?
          rejects << {
            row_number: row_number,
            reason: "row must have at least one of ccn or npi",
            raw: row.to_h
          }
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
          npi: npi,
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
