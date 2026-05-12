# frozen_string_literal: true

namespace :cms do
  namespace :cah do
    desc "Import CMS Critical Access Hospital list: rake cms:cah:import[/path/to/cah.csv,release_label,force]"
    task :import, [ :path, :label, :force ] => :environment do |_t, args|
      abort "Usage: rake cms:cah:import[/path/to/cah.csv,release_label,force]" unless args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      label = args[:label] || "manual"
      force = args[:force].to_s == "true"

      result = Corvid::CmsCahListParser.parse(File.read(args[:path]), release_label: label)
      rows = result[:rows]
      rejects = result[:rejects]

      # Within-file last-wins dedup that respects both partial unique
      # indexes — same NPI/date with different CCNs would otherwise
      # survive and crash insert_all.
      deduped = Corvid::CmsCahListParser.dedup_last_wins(rows)

      # Safety: a file where every parsed row got rejected (and the
      # current label has existing rows) would otherwise silently wipe
      # the prior good data. Require force=true to confirm.
      if deduped.empty? && rejects.any?
        existing = Corvid::CahFacility.where(source_release: label).count
        if existing.positive? && !force
          puts "ABORT: no valid rows parsed (#{rejects.size} rejected) but #{existing} row(s) exist for label=#{label}."
          puts "       Fix the file, or pass force=true as the third arg to wipe the release intentionally."
          rejects.each { |r| puts "       row #{r[:row_number]}: #{r[:reason]}" }
          exit 1
        end
      end

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
