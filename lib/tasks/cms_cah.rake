# frozen_string_literal: true

namespace :cms do
  namespace :cah do
    desc "Import CMS Critical Access Hospital list from a canonical CSV: rake cms:cah:import[/path/to/cah.csv,release_label]"
    task :import, [ :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:cah:import[/path/to/cah.csv,release_label]" unless args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      label = args[:label] || "manual"
      result = Corvid::CmsCahListParser.parse(File.read(args[:path]), release_label: label)
      rows = result[:rows]
      rejects = result[:rejects]

      # Dedup within the file by (ccn, effective_date), last-wins
      # (consistent with PrcImporter's within-file dedup convention).
      # Without this, repeated (ccn, effective_date) pairs would
      # violate idx_corvid_cah_ccn_effective on insert.
      deduped = rows.group_by { |r| [ r[:ccn], r[:effective_date] ] }.map { |_, g| g.last }

      now = Time.current
      ActiveRecord::Base.transaction do
        # Replace-by-release: previous rows from the same release are
        # cleared so a republished list with corrected effective_dates
        # doesn't accumulate stale duplicates. Rows from other releases
        # (different vintages, manual overrides) are preserved.
        Corvid::CahFacility.where(source_release: label).delete_all
        Corvid::CahFacility.insert_all(
          deduped.map { |r| r.merge(created_at: now, updated_at: now) }
        ) if deduped.any?
      end

      puts "Imported #{deduped.size} CAH facilities (label=#{label})"
      collapsed = rows.size - deduped.size
      puts "  collapsed #{collapsed} within-file duplicate(s) by (ccn, effective_date)" if collapsed.positive?
      if rejects.any?
        puts "  skipped #{rejects.size} invalid row(s):"
        rejects.each { |r| puts "    row #{r[:row_number]}: #{r[:reason]}" }
      end
    end
  end
end
