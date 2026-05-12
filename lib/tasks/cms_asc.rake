# frozen_string_literal: true

namespace :cms do
  namespace :asc do
    desc "Import CMS Ambulatory Surgical Center registry: rake cms:asc:import_facilities[/path/to/asc.csv,release_label]"
    task :import_facilities, [ :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:asc:import_facilities[/path/to/asc.csv,release_label]" unless args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      label = args[:label] || "manual"
      result = Corvid::CmsFacilityListParser.parse(File.read(args[:path]), release_label: label)
      rows = result[:rows]
      rejects = result[:rejects]

      deduped = Corvid::CmsFacilityListParser.dedup_last_wins(rows)

      Corvid::CmsFacilityListParser.replace_by_identifier_conflict(
        model_class: Corvid::AscFacility, rows: deduped, source_release: label
      )

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
