# frozen_string_literal: true

namespace :cms do
  namespace :cah do
    desc "Import CMS Critical Access Hospital list from a canonical CSV: rake cms:cah:import[/path/to/cah.csv,release_label]"
    task :import, [ :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:cah:import[/path/to/cah.csv,release_label]" unless args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      label = args[:label] || "manual"
      rows = Corvid::CmsCahListParser.parse(File.read(args[:path]), release_label: label)

      now = Time.current
      ActiveRecord::Base.transaction do
        # Replace-by-release: previous rows from the same release are
        # cleared so a republished list with corrected effective_dates
        # doesn't accumulate stale duplicates. Rows from other releases
        # (different vintages, manual overrides) are preserved.
        Corvid::CahFacility.where(source_release: label).delete_all
        Corvid::CahFacility.insert_all(
          rows.map { |r| r.merge(created_at: now, updated_at: now) }
        ) if rows.any?
      end

      puts "Imported #{rows.size} CAH facilities (label=#{label})"
    end
  end
end
