# frozen_string_literal: true

require "csv"

module Corvid
  # Parses a canonical CSV of CMS facility records (CAH, ASC, etc.)
  # into row hashes ready for upsert. Expected columns (header
  # required): effective_date plus at least one of {ccn, npi}.
  # Optional: facility_name, end_date. Comment lines starting with "#"
  # are skipped so the canonical file can carry a release_label marker
  # on its first line. Headers are case-insensitive and a UTF-8 BOM at
  # the start of the file is stripped (common from spreadsheets).
  #
  # Returns `{ rows: [...], rejects: [{row_number:, reason:, raw:}] }`.
  # Per-row validation drops (not raises) on missing both identifiers
  # or on a missing/malformed effective_date — consistent with
  # PrcImporter's permissive-but-report pattern. `row_number` references
  # the original file's line number, including any skipped comment
  # lines, so ops can locate the offending row directly in the source.
  #
  # Used by cms:cah:import (CahFacility) and cms:asc:import_facilities
  # (AscFacility); the parser is target-table-agnostic — each rake
  # task picks where the rows go.
  module CmsFacilityListParser
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
      raise ArgumentError, "facility CSV missing required columns: #{missing.join(', ')}" if missing.any?

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

    # Canonical-snapshot upsert. Each import is treated as the complete
    # truth for its source_release, so:
    #
    #   1. All prior rows tagged with the incoming source_release are
    #      wiped — a facility absent from the new snapshot must not
    #      remain in the registry.
    #   2. Rows in OTHER releases that conflict on (ccn, effective_date)
    #      or (npi, effective_date) are deleted so the partial unique
    #      indexes don't crash on insert and the latest publication is
    #      canonical.
    #   3. The new rows are bulk-inserted.
    #
    # source_release is the provenance label for the import; manual
    # rows tagged with a different source_release survive unless they
    # conflict with an incoming identifier/date tuple.
    #
    # An empty `rows` is a no-op even when source_release is given —
    # an accidentally-empty file should not silently wipe history.
    def self.replace_by_identifier_conflict(model_class:, rows:, source_release: nil)
      return if rows.empty?
      now = Time.current
      ActiveRecord::Base.transaction do
        model_class.where(source_release: source_release).delete_all if source_release

        rows.each do |r|
          conds = []
          vals = []
          if r[:ccn]
            conds << "(ccn = ? AND effective_date = ?)"
            vals << r[:ccn] << r[:effective_date]
          end
          if r[:npi]
            conds << "(npi = ? AND effective_date = ?)"
            vals << r[:npi] << r[:effective_date]
          end
          next if conds.empty?
          model_class.where(conds.join(" OR "), *vals).delete_all
        end

        model_class.insert_all(
          rows.map { |r| r.merge(created_at: now, updated_at: now) }
        )
      end
    end

    # Dedup parsed rows last-wins, respecting both unique-index
    # dimensions: (ccn, effective_date) and (npi, effective_date).
    # A row conflicts with a prior row when EITHER identifier matches
    # on the same effective_date. Without considering both axes, two
    # rows with the same NPI but different CCNs would survive dedup
    # and crash on the partial unique index at insert time.
    def self.dedup_last_wins(rows)
      result = []
      rows.each do |r|
        result.reject! do |prior|
          (r[:ccn] && prior[:ccn] == r[:ccn] && prior[:effective_date] == r[:effective_date]) ||
          (r[:npi] && prior[:npi] == r[:npi] && prior[:effective_date] == r[:effective_date])
        end
        result << r
      end
      result
    end

    def self.parse_date(value)
      return nil if value.nil? || value.strip.empty?
      Date.parse(value.strip)
    rescue ArgumentError
      nil
    end
  end
end
