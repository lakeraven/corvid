# frozen_string_literal: true

require "csv"

module Corvid
  # Normalizes a CMS ASC Addendum AA CSV ("ASC Covered Surgical
  # Procedures for CY {year}") into the canonical
  # `hcpcs_code,payment_indicator,payment_weight` shape that
  # AscHcpcsRate consumes.
  #
  # Addendum AA is published in the same zip as Addendum BB / DD1 / EE
  # / FF as part of the OPPS+ASC Final Rule each year. ASC publishes
  # per HCPCS (not per APC), so the data is HCPCS-keyed.
  #
  # Layout:
  #   - Two title rows at top (rule version, AMA copyright)
  #   - One blank row
  #   - Header row: HCPCS Code, (blank), Short Descriptor,
  #     Subject to Multiple Procedure Discounting,
  #     {Month} {Year} Payment Indicator,
  #     {Month} {Year} Payment Weight,
  #     {Month} {Year} Payment Rate
  #   - ~4800 data rows; only some have a Payment Weight.
  #
  # The header column names vary by year/quarter ("January 2026
  # Payment Weight" vs "January 2025 Payment Weight"), so column
  # resolution is by substring match on the label rather than exact
  # equality. Header lookup is case-insensitive and collapses
  # whitespace runs.
  module CmsAscAddendumAaNormalizer
    HEADER_MARKER = "HCPCS Code"

    class MalformedFileError < StandardError; end

    def self.normalize(addendum_aa_path)
      text = File.read(addendum_aa_path, encoding: "ISO-8859-1")
                 .encode("UTF-8", invalid: :replace, undef: :replace)
      # Normalize CRLF → LF (CMS files often ship with Windows line
      # endings) before parsing; Ruby's CSV.parse with liberal_parsing
      # doesn't auto-detect row separators reliably.
      text = text.gsub("\r\n", "\n").gsub("\r", "\n")
      rows = CSV.parse(text, liberal_parsing: true)

      header_idx = rows.index { |r| r[0]&.strip == HEADER_MARKER }
      raise MalformedFileError, "Addendum AA CSV missing HCPCS Code header row" if header_idx.nil?

      cols = column_indexes(rows[header_idx])

      rows[(header_idx + 1)..].filter_map.with_index do |row, i|
        line_number = header_idx + 2 + i
        hcpcs = row[cols[:hcpcs]]&.strip
        pi = row[cols[:pi]]&.strip
        weight_raw = row[cols[:weight]]&.strip
        next if hcpcs.nil? || hcpcs.empty?
        next if weight_raw.nil? || weight_raw.empty?
        next if weight_raw == "."

        weight = parse_weight(weight_raw, hcpcs: hcpcs, line: line_number)
        next unless weight.positive?
        {
          hcpcs_code: hcpcs,
          payment_indicator: pi.presence,
          payment_weight: weight
        }
      end
    end

    def self.render(rows, release_label:)
      body = CSV.generate do |csv|
        csv << %w[hcpcs_code payment_indicator payment_weight]
        rows.each do |r|
          csv << [ r[:hcpcs_code], r[:payment_indicator], format("%.4f", r[:payment_weight]) ]
        end
      end
      "# release_label: #{release_label}\n" + body
    end

    def self.parse_weight(raw, hcpcs:, line:)
      Float(raw.delete(",").delete("$"))
    rescue ArgumentError, TypeError
      raise MalformedFileError,
            "could not parse payment_weight=#{raw.inspect} as numeric " \
            "for HCPCS #{hcpcs} at source line #{line}"
    end

    # Header labels vary by year ("January 2026 Payment Indicator" vs
    # "January 2025 Payment Indicator"). Match by substring on the
    # significant words rather than exact equality.
    def self.column_indexes(header_row)
      normalized = header_row.map { |h| h.to_s.strip.downcase.gsub(/\s+/, " ") }
      {
        hcpcs: find_column(normalized, /\bhcpcs code\b/, "HCPCS Code"),
        pi: find_column(normalized, /\bpayment indicator\b/, "Payment Indicator"),
        weight: find_column(normalized, /\bpayment weight\b/, "Payment Weight")
      }
    end

    def self.find_column(normalized_headers, pattern, label)
      idx = normalized_headers.index { |h| h.match?(pattern) }
      raise MalformedFileError,
            "Addendum AA header missing required column matching #{label.inspect}; " \
            "got: #{normalized_headers.inspect}" if idx.nil?
      idx
    end
  end
end
