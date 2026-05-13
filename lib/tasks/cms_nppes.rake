# frozen_string_literal: true

require "csv"

namespace :cms do
  namespace :nppes do
    desc "Import the NPI↔CCN crosswalk: rake cms:nppes:import_crosswalk[/path/to/crosswalk.csv,release_label]"
    task :import_crosswalk, [ :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:nppes:import_crosswalk[/path/to/crosswalk.csv,release_label]" unless args[:path] && args[:label]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      label = args[:label]
      now = Time.current
      rows = []
      CSV.foreach(args[:path], headers: true) do |csv_row|
        npi = csv_row["npi"]&.strip
        ccn = csv_row["ccn"]&.strip
        next if npi.blank? || ccn.blank?

        rows << {
          npi: npi,
          ccn: ccn,
          effective_date: csv_row["effective_date"].presence,
          end_date: csv_row["end_date"].presence,
          source_release: label,
          created_at: now,
          updated_at: now
        }
      end

      ActiveRecord::Base.transaction do
        Corvid::NpiCcnCrosswalk.where(source_release: label).delete_all
        rows.each_slice(1000) do |batch|
          Corvid::NpiCcnCrosswalk.insert_all(batch)
        end if rows.any?
      end

      puts "Imported #{rows.size} NPI↔CCN crosswalk rows (label=#{label}, replaced prior snapshot)"
    end
  end
end
