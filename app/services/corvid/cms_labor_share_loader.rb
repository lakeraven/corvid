# frozen_string_literal: true

require "csv"

module Corvid
  # Loads db/data/cms_labor_shares.csv into corvid_cms_labor_shares.
  # One snapshot for every payment system and calendar year in the file.
  # Re-running replaces the table. An empty file is refused so a bad
  # path cannot wipe the shares the rate providers require. A labor_share
  # with more than four decimal places is malformed: load! raises
  # MalformedFileError before replacing the table, so a bad file loads
  # nothing.
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
        labor_text = row["labor_share"].to_s.strip
        labor_share = BigDecimal(labor_text)
        ensure_labor_share_decimals!(labor_text, labor_share, row)
        {
          payment_system: row["payment_system"].to_s.strip,
          calendar_year: Integer(row["calendar_year"].to_s.strip),
          labor_share: labor_share,
          source: row["source"].to_s.strip,
          release_label: row["release_label"].to_s.strip.presence
        }
      rescue ArgumentError => e
        raise MalformedFileError, "could not parse labor share row #{row.to_h.inspect}: #{e.message}"
      end

      # The column is numeric(5,4). Extra decimal digits would be rounded
      # on insert. Refuse the file instead, before delete_all.
      def ensure_labor_share_decimals!(labor_text, labor_share, row)
        fractional = labor_text.split(".", 2)[1]
        excess_digits = fractional&.match?(/\A\d{5,}\z/)
        excess_scale = labor_share.finite? &&
          labor_share != labor_share.round(CmsLaborShare::MAX_DECIMAL_PLACES)
        return unless excess_digits || excess_scale

        raise MalformedFileError,
              "labor_share has more than four decimal places in #{row.to_h.inspect}"
      end
    end
  end
end
