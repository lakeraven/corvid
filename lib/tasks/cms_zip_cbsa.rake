# frozen_string_literal: true

namespace :cms do
  namespace :zip_cbsa do
    desc "Import a ZIP to CBSA crosswalk from a canonical CSV: rake cms:zip_cbsa:import[year,/path/to/zip_cbsa.csv,release_label]"
    task :import, [ :year, :path, :label ] => :environment do |_t, args|
      unless args[:year] && args[:path]
        abort "Usage: rake cms:zip_cbsa:import[year,/path/to/zip_cbsa.csv,release_label]"
      end
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      label = args[:label].presence || "manual"
      rows = Corvid::CmsZipCbsaParser.parse(
        File.read(args[:path]), fiscal_year: year, release_label: label
      )

      ActiveRecord::Base.transaction do
        Corvid::ZipCbsaCrosswalk.where(fiscal_year: year).delete_all
        if rows.any?
          now = Time.current
          stamped = rows.map { |row| row.merge(created_at: now, updated_at: now) }
          Corvid::ZipCbsaCrosswalk.insert_all(stamped)
        end
      end

      puts "Imported #{rows.size} ZIP to CBSA rows for FY #{year} (label=#{label}, replaced full year snapshot)"
    end
  end
end
