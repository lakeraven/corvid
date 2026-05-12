# frozen_string_literal: true

namespace :cms do
  namespace :cah do
    desc "Import CMS Critical Access Hospital list: rake cms:cah:import[/path/to/cah.csv,release_label]"
    task :import, [ :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:cah:import[/path/to/cah.csv,release_label]" unless args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      label = args[:label] || "manual"
      result = Corvid::CmsFacilityListParser.parse(File.read(args[:path]), release_label: label)
      rows = result[:rows]
      rejects = result[:rejects]

      deduped = Corvid::CmsFacilityListParser.dedup_last_wins(rows)

      Corvid::CmsFacilityListParser.replace_by_identifier_conflict(
        model_class: Corvid::CahFacility, rows: deduped
      )

      puts "Imported #{deduped.size} CAH facilities (label=#{label})"
      collapsed = rows.size - deduped.size
      puts "  collapsed #{collapsed} within-file duplicate(s)" if collapsed.positive?
      if rejects.any?
        puts "  skipped #{rejects.size} invalid row(s):"
        rejects.each { |r| puts "    row #{r[:row_number]}: #{r[:reason]}" }
      end
    end
  end
end
