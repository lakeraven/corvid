# frozen_string_literal: true

require "csv"

module Corvid
  # Normalizes the CMS Provider of Services (POS) Hospital-and-Other
  # file into the canonical CAH facility list shape that
  # CmsFacilityListParser consumes.
  #
  # The POS file is the authoritative source for Medicare-certified
  # provider data — published quarterly at data.cms.gov, ~30 MB CSV
  # covering ~45K facilities. We filter to Critical Access Hospitals
  # (PRVDR_CTGRY_CD = '01' Hospital + PRVDR_CTGRY_SBTYP_CD = '11'
  # CAH subtype) and emit the columns CmsFacilityListParser expects.
  #
  # Date fields in POS are YYYYMMDD strings; we convert to YYYY-MM-DD.
  # Active CAHs (PGM_TRMNTN_CD = '00') leave end_date blank.
  # Terminated CAHs use TRMNTN_EXPRTN_DT — required when terminated;
  # a terminated row with a missing or malformed termination date is
  # rejected (NOT emitted with end_date: nil) because downstream
  # CahFacility#applies? treats nil end_date as open-ended, which
  # would silently grant the 1.01× multiplier to terminated facilities.
  #
  # Returns `{ rows: [...], rejects: [{ccn:, reason:}] }` — consistent
  # with CmsFacilityListParser's permissive-but-report pattern.
  module CmsPosCahNormalizer
    HOSPITAL_CATEGORY = "01"
    CAH_SUBTYPE = "11"
    ACTIVE_TERMINATION_CODE = "00"

    REQUIRED_COLUMNS = %w[
      PRVDR_NUM FAC_NAME
      PRVDR_CTGRY_CD PRVDR_CTGRY_SBTYP_CD
      ORGNL_PRTCPTN_DT PGM_TRMNTN_CD TRMNTN_EXPRTN_DT
    ].freeze

    BOM = "\xEF\xBB\xBF".b

    class MalformedFileError < StandardError; end

    def self.normalize(pos_csv_path)
      validate_header!(pos_csv_path)

      rows = []
      rejects = []
      CSV.foreach(pos_csv_path, headers: true) do |row|
        next unless row["PRVDR_CTGRY_CD"] == HOSPITAL_CATEGORY
        next unless row["PRVDR_CTGRY_SBTYP_CD"] == CAH_SUBTYPE

        ccn = row["PRVDR_NUM"]&.strip
        next if ccn.nil? || ccn.empty?

        # ORGNL_PRTCPTN_DT is when the facility first became
        # Medicare-CAH-certified — the right anchor for "when does the
        # 1.01× multiplier apply from?". CRTFCTN_DT changes on re-survey
        # events and would shift the effective_date forward incorrectly.
        effective = parse_yyyymmdd(row["ORGNL_PRTCPTN_DT"])
        next if effective.nil?

        terminated = row["PGM_TRMNTN_CD"] != ACTIVE_TERMINATION_CODE
        if terminated
          end_date = parse_yyyymmdd(row["TRMNTN_EXPRTN_DT"])
          if end_date.nil?
            rejects << {
              ccn: ccn,
              reason: "terminated CAH (PGM_TRMNTN_CD=#{row['PGM_TRMNTN_CD'].inspect}) " \
                      "with missing or malformed TRMNTN_EXPRTN_DT " \
                      "(#{row['TRMNTN_EXPRTN_DT'].inspect}); skipping to avoid " \
                      "matching forever as 'active' downstream"
            }
            next
          end
        else
          end_date = nil
        end

        rows << {
          ccn: ccn,
          npi: nil, # POS file doesn't carry NPI; cross-walk from NPPES is a separate step
          facility_name: row["FAC_NAME"]&.strip.presence,
          effective_date: effective,
          end_date: end_date
        }
      end
      { rows: rows, rejects: rejects }
    end

    # Render canonical CAH list CSV in the shape CmsFacilityListParser
    # expects (effective_date required; npi optional). First line is
    # the # release_label: marker.
    def self.render(rows, release_label:)
      body = CSV.generate do |csv|
        csv << %w[ccn npi facility_name effective_date end_date]
        rows.each do |r|
          csv << [
            r[:ccn],
            r[:npi],
            r[:facility_name],
            r[:effective_date],
            r[:end_date]
          ]
        end
      end
      "# release_label: #{release_label}\n" + body
    end

    # Validate headers using CSV.parse_line so BOM + quoted-header
    # edge cases are handled the same way the row loop does.
    def self.validate_header!(pos_csv_path)
      first_line = File.open(pos_csv_path, "rb") { |f| f.readline }
      first_line = first_line.b
      first_line = first_line.sub(/\A#{BOM}/, "").force_encoding("UTF-8")
      headers = CSV.parse_line(first_line) || []
      missing = REQUIRED_COLUMNS - headers
      return if missing.empty?

      raise MalformedFileError,
            "POS CSV missing required columns: #{missing.join(', ')}; " \
            "got: #{headers.inspect}"
    end

    def self.parse_yyyymmdd(value)
      return nil if value.nil? || value.strip.empty?
      Date.strptime(value.strip, "%Y%m%d").iso8601
    rescue ArgumentError
      nil
    end
  end
end
