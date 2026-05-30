# frozen_string_literal: true

require "csv"
require "date"
require "bigdecimal"

module Corvid
  # Normalizes the RPMS CHS Document Transaction Report (TRD) — already
  # converted to a canonical CSV shape by an upstream preprocessor — into
  # structured rows the PRC overpayment analyzer can consume.
  #
  # This is the first slice of the CHS TRD ingestion path (corvid#385).
  # The TRD-text-format-to-canonical-CSV preprocessor is a follow-up; this
  # service starts from the canonical CSV contract:
  #
  #   document_number,patient_dfn,vendor_name,procedure_code,service_date,paid_amount
  #   1234567,12345,ACME REGIONAL HOSPITAL,99213,2024-06-15,180.00
  #
  # Required columns (header validation aborts with ArgumentError if any
  # are missing):
  #   document_number, vendor_name, procedure_code, service_date, paid_amount
  #
  # Optional pass-through columns (tolerated without rejection):
  #   patient_dfn, place_of_service, modifiers, drg, apc, facility_zip
  #
  # Strict parsing — garbage rejects rather than silently coercing:
  #   - service_date via Date.iso8601 (raise → reject)
  #   - paid_amount  via BigDecimal   (raise → reject)
  #
  # Returns `{ rows: [...], rejects: [...] }`:
  #   - rows: Hash with symbol keys, required strings stripped, optional
  #           fields nil when absent
  #   - rejects: [{ line:, reason: }] — line is 1-indexed CSV body line
  #
  # Mirrors the canonical-CSV pattern from CmsPosCahNormalizer /
  # CmsPosAscNormalizer; numeric strictness mirrors CmsFeeScheduleParser
  # / CmsAscParser.
  module ChsTrdNormalizer
    REQUIRED_COLUMNS = %w[
      document_number vendor_name procedure_code service_date paid_amount
    ].freeze

    OPTIONAL_COLUMNS = %w[
      patient_dfn place_of_service modifiers drg apc facility_zip
    ].freeze

    REQUIRED_STRING_FIELDS = %w[document_number vendor_name procedure_code].freeze

    BOM = "\xEF\xBB\xBF".b

    def self.normalize(csv_string_or_io)
      raw = csv_string_or_io.respond_to?(:read) ? csv_string_or_io.read : csv_string_or_io.to_s
      raw = raw.b
      raw = raw[BOM.bytesize..] if raw.start_with?(BOM)
      text = raw.force_encoding("UTF-8")

      table = CSV.parse(text, headers: true)
      headers = (table.headers || []).map { |h| h.to_s.strip }
      missing = REQUIRED_COLUMNS - headers
      if missing.any?
        raise ArgumentError,
              "CHS TRD CSV missing required columns: #{missing.join(', ')}; " \
              "got: #{headers.inspect}"
      end

      rows = []
      rejects = []
      table.each_with_index do |row, idx|
        line = idx + 1
        normalized, reason = normalize_row(row)
        if reason
          rejects << { line: line, reason: reason }
        else
          rows << normalized
        end
      end
      { rows: rows, rejects: rejects }
    end

    # Returns [row_hash, nil] on success, [nil, reason_string] on reject.
    def self.normalize_row(row)
      required = {}
      REQUIRED_STRING_FIELDS.each do |field|
        value = row[field].to_s.strip
        return [ nil, "missing required field: #{field}" ] if value.empty?
        required[field.to_sym] = value
      end

      service_date_raw = row["service_date"].to_s.strip
      return [ nil, "missing required field: service_date" ] if service_date_raw.empty?
      begin
        service_date = Date.iso8601(service_date_raw).iso8601
      rescue ArgumentError, TypeError
        return [ nil, "malformed service_date: #{service_date_raw.inspect}" ]
      end

      paid_amount_raw = row["paid_amount"].to_s.strip
      return [ nil, "missing required field: paid_amount" ] if paid_amount_raw.empty?
      cleaned = paid_amount_raw.delete(",").sub(/\A\$/, "")
      begin
        paid_amount = BigDecimal(cleaned)
      rescue ArgumentError, TypeError
        return [ nil, "malformed paid_amount: #{paid_amount_raw.inspect}" ]
      end

      result = {
        document_number: required[:document_number],
        vendor_name: required[:vendor_name],
        procedure_code: required[:procedure_code],
        service_date: service_date,
        paid_amount: paid_amount
      }
      OPTIONAL_COLUMNS.each do |col|
        value = row.headers.include?(col) ? row[col]&.to_s&.strip : nil
        result[col.to_sym] = (value && !value.empty?) ? value : nil
      end
      [ result, nil ]
    end
    private_class_method :normalize_row
  end
end
