# frozen_string_literal: true

namespace :cms do
  namespace :cah do
    desc "Normalize a CMS POS hospital file into the canonical CAH CSV: rake cms:cah:normalize_pos[/path/to/pos.csv,/path/to/output.csv,release_label]"
    task :normalize_pos, [ :input, :output, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:cah:normalize_pos[input.csv,output.csv,release_label]" unless args[:input] && args[:output]
      abort "Input not found: #{args[:input]}" unless File.exist?(args[:input])

      label = args[:label] || "cms_pos_manual"
      result = Corvid::CmsPosCahNormalizer.normalize(args[:input])
      rows = result[:rows]
      rejects = result[:rejects]
      csv = Corvid::CmsPosCahNormalizer.render(rows, release_label: label)
      File.write(args[:output], csv)
      active = rows.count { |r| r[:end_date].nil? }
      puts "Wrote #{rows.size} CAHs (#{active} active, #{rows.size - active} terminated) to #{args[:output]} (label=#{label})"
      if rejects.any?
        puts "  skipped #{rejects.size} CAH row(s):"
        rejects.each { |r| puts "    ccn=#{r[:ccn]}: #{r[:reason]}" }
      end
    end

    desc "Wipe all CAH rows tagged with a given source_release: rake cms:cah:clear[release_label]"
    task :clear, [ :label ] => :environment do |_t, args|
      abort "Usage: rake cms:cah:clear[release_label]" unless args[:label]
      count = Corvid::CahFacility.where(source_release: args[:label]).count
      Corvid::CahFacility.where(source_release: args[:label]).delete_all
      puts "Cleared #{count} CAH facilities for label=#{args[:label]}"
    end

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
        model_class: Corvid::CahFacility, rows: deduped, source_release: label
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
