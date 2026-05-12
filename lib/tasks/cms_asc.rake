# frozen_string_literal: true

namespace :cms do
  namespace :asc do
    desc "Import CMS Ambulatory Surgical Center registry: rake cms:asc:import_facilities[/path/to/asc.csv,release_label,force]"
    task :import_facilities, [ :path, :label, :force ] => :environment do |_t, args|
      abort "Usage: rake cms:asc:import_facilities[/path/to/asc.csv,release_label,force]" unless args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      label = args[:label] || "manual"
      force = args[:force].to_s == "true"

      result = Corvid::CmsFacilityListParser.parse(File.read(args[:path]), release_label: label)
      rows = result[:rows]
      rejects = result[:rejects]

      deduped = Corvid::CmsFacilityListParser.dedup_last_wins(rows)

      # Safety guard: a file where every parsed row got rejected (and
      # the current label has existing rows) would otherwise silently
      # wipe the prior good data. Require force=true to confirm.
      if deduped.empty? && rejects.any?
        existing = Corvid::AscFacility.where(source_release: label).count
        if existing.positive? && !force
          puts "ABORT: no valid rows parsed (#{rejects.size} rejected) but #{existing} row(s) exist for label=#{label}."
          puts "       Fix the file, or pass force=true as the third arg to wipe the release intentionally."
          rejects.each { |r| puts "       row #{r[:row_number]}: #{r[:reason]}" }
          exit 1
        end
      end

      now = Time.current
      ActiveRecord::Base.transaction do
        Corvid::AscFacility.where(source_release: label).delete_all
        Corvid::AscFacility.insert_all(
          deduped.map { |r| r.merge(created_at: now, updated_at: now) }
        ) if deduped.any?
      end

      puts "Imported #{deduped.size} ASC facilities (label=#{label})"
      collapsed = rows.size - deduped.size
      puts "  collapsed #{collapsed} within-file duplicate(s)" if collapsed.positive?
      if rejects.any?
        puts "  skipped #{rejects.size} invalid row(s):"
        rejects.each { |r| puts "    row #{r[:row_number]}: #{r[:reason]}" }
      end
    end
  end
end
