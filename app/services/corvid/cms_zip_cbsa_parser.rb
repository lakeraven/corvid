# frozen_string_literal: true

require "csv"

module Corvid
  # Parses the canonical ZIP → CBSA CSV (`zip,cbsa`). Leading `#` lines
  # are comments, matching the other CMS importers. `fiscal_year` and
  # `release_label` are stamped by the caller. A file comment is not a
  # release label. CMS files are year-specific by filename.
  #
  # Input is parsed from a UTF-8 copy. Invalid encodings raise
  # ArgumentError and never echo the bytes. A bad row names the line
  # number and never the field values. A carriage return still in a
  # line after one trailing LF or CRLF is removed is an error on that
  # line (comment, header, or data) and never echoes the line.
  module CmsZipCbsaParser
    HEADER = %w[zip cbsa].freeze

    class << self
      def parse(csv_text, fiscal_year:, release_label:)
        lines = normalize_text(csv_text).lines
        reject_embedded_carriage_returns!(lines)
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
        text = csv_text.to_s.dup
        text.force_encoding(Encoding::UTF_8)
        raise ArgumentError, "invalid encoding: expected UTF-8" unless text.valid_encoding?

        text.sub(/\A\xEF\xBB\xBF/, "")
      end

      def header_index(lines)
        index = lines.index { |line| !ignorable_line?(line) }
        raise ArgumentError, "missing header row; expected zip,cbsa" if index.nil?

        fields = header_fields(lines[index], index + 1)
        return index if fields == HEADER

        raise ArgumentError, header_message(index + 1)
      end

      def header_fields(line, line_no)
        Array(CSV.parse_line(logical_line(line, line_no, header: true).strip)).map { |field| field.to_s.strip }
      rescue CSV::MalformedCSVError
        raise ArgumentError, header_message(line_no)
      end

      def header_message(line_no)
        "missing header row; expected zip,cbsa on line #{line_no}"
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
        fields = Array(CSV.parse_line(logical_line(line, line_no, header: false).strip)).map { |field| field.to_s.strip }
        raise ArgumentError, "malformed row on line #{line_no}" unless fields.length == 2

        fields
      rescue CSV::MalformedCSVError
        raise ArgumentError, "malformed row on line #{line_no}"
      end

      def logical_line(line, line_no, header:)
        body = without_trailing_break(line)
        reject_carriage_return!(body, line_no, header: header)
        body
      end

      # Every line is checked before it can be skipped as a comment or
      # blank. One trailing LF or CRLF is a record separator; any other
      # CR is an error and the message names only the line number.
      def reject_embedded_carriage_returns!(lines)
        seen_header = false
        lines.each_with_index do |line, index|
          body = without_trailing_break(line)
          if body.include?("\r")
            header = !seen_header && !ignorable_line?(body)
            reject_carriage_return!(body, index + 1, header: header)
          else
            seen_header ||= !ignorable_line?(body)
          end
        end
      end

      def reject_carriage_return!(body, line_no, header:)
        return unless body.include?("\r")

        raise ArgumentError, header ? header_message(line_no) : "malformed row on line #{line_no}"
      end

      def without_trailing_break(line)
        text = line.to_s
        return text.delete_suffix("\r\n") if text.end_with?("\r\n")
        return text.delete_suffix("\n") if text.end_with?("\n")

        text
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
