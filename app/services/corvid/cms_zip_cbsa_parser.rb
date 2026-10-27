# frozen_string_literal: true

require "csv"

module Corvid
  # Parses the canonical ZIP → CBSA CSV (`zip,cbsa`). Leading `#` lines
  # are comments, matching the other CMS importers. `fiscal_year` is
  # stamped by the caller — CMS files are year-specific by filename.
  #
  # ArgumentError names the line number and never the field values.
  module CmsZipCbsaParser
    HEADER = %w[zip cbsa].freeze

    class << self
      def parse(csv_text, fiscal_year:, release_label:)
        lines = normalize_text(csv_text).lines
        start = header_index(lines)
        seen = {}
        rows = []
        lines.each_with_index do |line, index|
          next if index <= start || ignorable_line?(line)

          rows << row_for(line, index + 1, fiscal_year, release_label, seen)
        end
        rows
      end

      private

      def normalize_text(csv_text)
        csv_text.to_s.sub(/\A\xEF\xBB\xBF/, "").sub(/\A\uFEFF/, "")
      end

      def header_index(lines)
        index = lines.index { |line| !ignorable_line?(line) }
        raise ArgumentError, "missing header row; expected zip,cbsa" if index.nil?

        fields = header_fields(lines[index], index + 1)
        return index if fields == HEADER

        raise ArgumentError, "missing header row; expected zip,cbsa on line #{index + 1}"
      end

      def header_fields(line, line_no)
        Array(CSV.parse_line(line.to_s.strip)).map { |field| field.to_s.strip }
      rescue CSV::MalformedCSVError
        raise ArgumentError, "missing header row; expected zip,cbsa on line #{line_no}"
      end

      def row_for(line, line_no, fiscal_year, release_label, seen)
        zip, cbsa = split_fields(line, line_no)
        validate_field!(zip, ZipCbsaCrosswalk::ZIP_FORMAT, "zip", line_no)
        validate_field!(cbsa, ZipCbsaCrosswalk::CBSA_FORMAT, "cbsa", line_no)
        raise ArgumentError, "duplicate zip on line #{line_no}" if seen[zip]

        seen[zip] = true
        { fiscal_year: fiscal_year, zip: zip, cbsa: cbsa, release_label: release_label }
      end

      def split_fields(line, line_no)
        fields = Array(CSV.parse_line(line.to_s.strip)).map { |field| field.to_s.strip }
        raise ArgumentError, "malformed row on line #{line_no}" unless fields.length == 2

        fields
      rescue CSV::MalformedCSVError
        raise ArgumentError, "malformed row on line #{line_no}"
      end

      def validate_field!(value, format, name, line_no)
        return if value.match?(format)

        raise ArgumentError, "malformed #{name} on line #{line_no}"
      end

      def ignorable_line?(line)
        stripped = line.strip
        stripped.empty? || stripped.start_with?("#")
      end
    end
  end
end
