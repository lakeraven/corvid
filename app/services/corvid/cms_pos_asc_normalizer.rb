# frozen_string_literal: true

require "csv"

module Corvid
  # Normalizes the CMS iQIES Provider of Services file (HHA / ASC /
  # Hospice) into the canonical ASC facility list shape that
  # CmsFacilityListParser consumes.
  #
  # Different file from the Hospital POS used for CAH:
  #   - lowercase column names (`prvdr_num` vs `PRVDR_NUM`)
  #   - dates already YYYY-MM-DD (vs YYYYMMDD)
  #   - termination indicated by `trmntn_exprtn_dt` content
  #     (literal "Not Available" for active; an actual date for terminated)
  #     — no separate termination-code column
  #
  # We filter to ASCs (prvdr_type_id = '11') and emit the columns
  # CmsFacilityListParser expects. ASC CCNs use letter-prefix format
  # like "17C0001897" — pass through verbatim.
  #
  # Returns `{ rows: [...], rejects: [{ccn:, reason:}] }`.
  module CmsPosAscNormalizer
    ASC_PROVIDER_TYPE = "11"
    NOT_AVAILABLE_SENTINEL = "Not Available"

    REQUIRED_COLUMNS = %w[
      prvdr_num fac_name prvdr_type_id
      orgnl_prtcptn_dt trmntn_exprtn_dt
    ].freeze

    BOM = "\xEF\xBB\xBF".b

    class MalformedFileError < StandardError; end

    def self.normalize(pos_csv_path)
      validate_header!(pos_csv_path)

      rows = []
      rejects = []
      CSV.foreach(pos_csv_path, headers: true) do |row|
        next unless row["prvdr_type_id"] == ASC_PROVIDER_TYPE

        ccn = row["prvdr_num"]&.strip
        next if ccn.nil? || ccn.empty?

        effective = parse_iso8601(row["orgnl_prtcptn_dt"])
        next if effective.nil?

        term_raw = row["trmntn_exprtn_dt"]&.strip
        terminated = !term_raw.nil? && term_raw != NOT_AVAILABLE_SENTINEL && !term_raw.empty?

        end_date = nil
        if terminated
          end_date = parse_iso8601(term_raw)
          if end_date.nil?
            rejects << {
              ccn: ccn,
              reason: "ASC with malformed trmntn_exprtn_dt " \
                      "(#{row['trmntn_exprtn_dt'].inspect}); skipping to avoid " \
                      "matching forever as 'active' downstream"
            }
            next
          end
        end

        rows << {
          ccn: ccn,
          npi: nil,
          facility_name: row["fac_name"]&.strip.presence,
          effective_date: effective,
          end_date: end_date
        }
      end
      { rows: rows, rejects: rejects }
    end

    def self.render(rows, release_label:)
      body = CSV.generate do |csv|
        csv << %w[ccn npi facility_name effective_date end_date]
        rows.each do |r|
          csv << [ r[:ccn], r[:npi], r[:facility_name], r[:effective_date], r[:end_date] ]
        end
      end
      "# release_label: #{release_label}\n" + body
    end

    def self.validate_header!(pos_csv_path)
      first_line = File.open(pos_csv_path, "rb") { |f| f.readline }
      first_line = first_line.b.sub(/\A#{BOM}/, "").force_encoding("UTF-8")
      headers = CSV.parse_line(first_line) || []
      missing = REQUIRED_COLUMNS - headers
      return if missing.empty?

      raise MalformedFileError,
            "iQIES POS CSV missing required columns: #{missing.join(', ')}; " \
            "got: #{headers.inspect}"
    end

    # iQIES dates are already ISO 8601 (YYYY-MM-DD). Parse via Date for
    # validation; return the original string if valid.
    def self.parse_iso8601(value)
      return nil if value.nil?
      stripped = value.strip
      return nil if stripped.empty? || stripped == NOT_AVAILABLE_SENTINEL
      Date.parse(stripped).iso8601
    rescue ArgumentError
      nil
    end
  end
end
