# frozen_string_literal: true

require "csv"
require "date"

namespace :cms do
  namespace :nppes do
    REQUIRED_HEADERS = %w[npi ccn effective_date end_date].freeze

    desc "Import the NPI↔CCN crosswalk: rake cms:nppes:import_crosswalk[/path/to/crosswalk.csv,release_label]"
    task :import_crosswalk, [ :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:nppes:import_crosswalk[/path/to/crosswalk.csv,release_label]" unless args[:path] && args[:label]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      csv = CSV.read(args[:path], headers: true)
      missing = REQUIRED_HEADERS - (csv.headers || []).map { |h| h&.strip }
      abort "Missing required headers: #{missing.join(', ')}" if missing.any?

      label = args[:label]
      now = Time.current
      rows = []
      rejects = []

      csv.each_with_index do |csv_row, idx|
        line = idx + 2 # +1 for header, +1 to 1-index
        npi = csv_row["npi"]&.strip
        ccn = csv_row["ccn"]&.strip
        next if npi.blank? && ccn.blank? && csv_row.to_h.values.all? { |v| v.to_s.strip.empty? }

        if npi.blank? || ccn.blank?
          rejects << { line: line, reason: "missing npi or ccn" }
          next
        end

        begin
          effective_date = parse_optional_date(csv_row["effective_date"])
          end_date = parse_optional_date(csv_row["end_date"])
        rescue ArgumentError => e
          rejects << { line: line, reason: e.message }
          next
        end

        rows << {
          npi: npi,
          ccn: ccn,
          effective_date: effective_date,
          end_date: end_date,
          source_release: label,
          created_at: now,
          updated_at: now
        }
      end

      if rows.empty?
        msg = "No usable rows in #{args[:path]} (refusing to wipe snapshot for label=#{label})"
        msg += "; #{rejects.size} row(s) rejected" if rejects.any?
        abort msg
      end

      ActiveRecord::Base.transaction do
        Corvid::NpiCcnCrosswalk.where(source_release: label).delete_all
        rows.each_slice(1000) do |batch|
          Corvid::NpiCcnCrosswalk.insert_all(batch)
        end
      end

      puts "Imported #{rows.size} NPI↔CCN crosswalk rows (label=#{label}, replaced prior snapshot)"
      if rejects.any?
        puts "  skipped #{rejects.size} invalid row(s):"
        rejects.each { |r| puts "    line #{r[:line]}: #{r[:reason]}" }
      end
    end

    # Blank → nil (legitimate permissive bound). Garbage → raises so
    # the row is rejected rather than silently coerced to nil (which
    # would create an unbounded match window).
    def parse_optional_date(raw)
      stripped = raw.to_s.strip
      return nil if stripped.empty?
      Date.iso8601(stripped)
    rescue ArgumentError
      raise ArgumentError, "invalid date: #{raw.inspect}"
    end
  end
end
