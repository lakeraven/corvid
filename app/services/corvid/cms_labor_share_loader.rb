# frozen_string_literal: true

require "csv"

module Corvid
  # Loads db/data/cms_labor_shares.csv into corvid_cms_labor_shares.
  # One snapshot for every payment system and calendar year in the file.
  # Re-running replaces the table. An empty file is refused so a bad
  # path cannot wipe the shares the rate providers require.
  class CmsLaborShareLoader
    DEFAULT_PATH = Engine.root.join("db/data/cms_labor_shares.csv")
    HEADERS = %w[payment_system calendar_year labor_share source release_label].freeze

    class MalformedFileError < StandardError; end

    class << self
      def load!(path: DEFAULT_PATH)
        rows = parse(File.read(path))
        raise MalformedFileError, "no labor share data rows; table left unchanged" if rows.empty?

        CmsLaborShare.transaction(requires_new: true) do
          CmsLaborShare.delete_all
          rows.each { |attrs| CmsLaborShare.create!(attrs) }
        end
        rows.size
      end

      def parse(text)
        body = text.lines.reject { |line| line.lstrip.start_with?("#") }.join
        table = CSV.parse(body, headers: true)
        missing = HEADERS - Array(table.headers)
        raise MalformedFileError, "missing columns: #{missing.join(', ')}" if missing.any?

        seen = {}
        table.filter_map do |row|
          next if row.fields.all? { |value| value.to_s.strip.empty? }

          attrs = attributes_for(row)
          key = [ attrs[:payment_system], attrs[:calendar_year] ]
          if seen[key]
            raise MalformedFileError, "duplicate labor share for #{key.join(' ')}"
          end

          seen[key] = true
          attrs
        end
      end

      private

      def attributes_for(row)
        {
          payment_system: row["payment_system"].to_s.strip,
          calendar_year: Integer(row["calendar_year"].to_s.strip),
          labor_share: BigDecimal(row["labor_share"].to_s.strip),
          source: row["source"].to_s.strip,
          release_label: row["release_label"].to_s.strip.presence
        }
      rescue ArgumentError => e
        raise MalformedFileError, "could not parse labor share row #{row.to_h.inspect}: #{e.message}"
      end
    end
  end
end
