# frozen_string_literal: true

require "csv"

namespace :cms do
  namespace :asc do
    desc "Import ASC conversion factors from a canonical CSV: rake cms:asc:import_conversion_factors[year,/path/to/asc_cf.csv,release_label]"
    task :import_conversion_factors, [ :year, :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:asc:import_conversion_factors[year,/path/to/asc_cf.csv,release_label]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      label = args[:label] || "manual"
      rows = Corvid::CmsAscParser.parse_conversion_factors(
        File.read(args[:path]), calendar_year: year, release_label: label
      )
      now = Time.current
      ActiveRecord::Base.transaction do
        Corvid::AscConversionFactor.where(calendar_year: year).delete_all
        Corvid::AscConversionFactor.insert_all(
          rows.map { |r| r.merge(created_at: now, updated_at: now) }
        ) if rows.any?
      end
      puts "Imported #{rows.size} ASC conversion factors for CY #{year} (label=#{label}, replaced full year snapshot)"
    end

    desc "Normalize a CMS ASC Addendum AA CSV into the canonical hcpcs_weights CSV: rake cms:asc:normalize_addendum_aa[year,input,output,release_label]"
    task :normalize_addendum_aa, [ :year, :input, :output, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:asc:normalize_addendum_aa[year,input.csv,output.csv,release_label]" unless args[:year] && args[:input] && args[:output]
      abort "Input not found: #{args[:input]}" unless File.exist?(args[:input])

      label = args[:label] || "cms_asc_cy#{args[:year]}_final_rule"
      rows = Corvid::CmsAscAddendumAaNormalizer.normalize(args[:input])
      csv = Corvid::CmsAscAddendumAaNormalizer.render(rows, release_label: label)
      File.write(args[:output], csv)
      puts "Wrote #{rows.size} ASC HCPCS rates to #{args[:output]} (label=#{label})"
    end

    desc "Import ASC HCPCS rates from a canonical CSV: rake cms:asc:import_hcpcs_rates[year,/path/to/asc_hcpcs.csv,release_label]"
    task :import_hcpcs_rates, [ :year, :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:asc:import_hcpcs_rates[year,/path/to/asc_hcpcs.csv,release_label]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      label = args[:label] || "manual"
      rows = Corvid::CmsAscParser.parse_hcpcs_rates(
        File.read(args[:path]), calendar_year: year, release_label: label
      )
      now = Time.current
      ActiveRecord::Base.transaction do
        Corvid::AscHcpcsRate.where(calendar_year: year).delete_all
        rows.each_slice(500) do |batch|
          Corvid::AscHcpcsRate.insert_all(
            batch.map { |r| r.merge(created_at: now, updated_at: now) }
          )
        end
      end
      puts "Imported #{rows.size} ASC HCPCS rates for CY #{year} (label=#{label}, replaced full year snapshot)"
    end

    desc "Wipe all ASC rows tagged with a given source_release: rake cms:asc:clear_facilities[release_label]"
    task :clear_facilities, [ :label ] => :environment do |_t, args|
      abort "Usage: rake cms:asc:clear_facilities[release_label]" unless args[:label]
      count = Corvid::AscFacility.where(source_release: args[:label]).count
      Corvid::AscFacility.where(source_release: args[:label]).delete_all
      puts "Cleared #{count} ASC facilities for label=#{args[:label]}"
    end

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
