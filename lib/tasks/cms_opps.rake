# frozen_string_literal: true

require "open-uri"

namespace :cms do
  namespace :opps do
    desc "Import CMS OPPS APC weights from a canonical CSV: rake cms:opps:import_apc_weights[year,/path/to/apc_weights.csv,release_label]"
    task :import_apc_weights, [ :year, :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:opps:import_apc_weights[year,/path/to/apc_weights.csv,release_label]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      label = args[:label] || "manual"
      rows = Corvid::CmsOppsParser.parse_apc_weights(
        File.read(args[:path]), calendar_year: year, release_label: label
      )

      ActiveRecord::Base.transaction do
        Corvid::OppsApcWeight.where(calendar_year: year).delete_all
        Corvid::OppsApcWeight.insert_all(rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if rows.any?
      end

      puts "Imported #{rows.size} APC weights for CY #{year} (label=#{label}, replaced full year snapshot)"
    end

    desc "Import CMS OPPS conversion factors from a canonical CSV: rake cms:opps:import_conversion_factors[year,/path/to/conversion_factors.csv,release_label]"
    task :import_conversion_factors, [ :year, :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:opps:import_conversion_factors[year,/path/to/conversion_factors.csv,release_label]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      label = args[:label] || "manual"
      rows = Corvid::CmsOppsParser.parse_conversion_factors(
        File.read(args[:path]), calendar_year: year, release_label: label
      )

      ActiveRecord::Base.transaction do
        Corvid::OppsConversionFactor.where(calendar_year: year).delete_all
        Corvid::OppsConversionFactor.insert_all(rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if rows.any?
      end

      puts "Imported #{rows.size} conversion factors for CY #{year} (label=#{label}, replaced full year snapshot)"
    end

    OPPS_RELEASE_BASE_URL = "https://github.com/lakeraven/corvid/releases/download/cms-fee-schedules-v1"

    desc "Fetch + import OPPS canonical CSVs from the cms-fee-schedules-v1 GitHub Release: rake cms:opps:fetch_release[year]"
    task :fetch_release, [ :year ] => :environment do |_t, args|
      abort "Usage: rake cms:opps:fetch_release[year]" unless args[:year]
      year = args[:year].to_i

      apc_url = "#{OPPS_RELEASE_BASE_URL}/opps_apc_weights_CY#{year}.csv"
      cf_url  = "#{OPPS_RELEASE_BASE_URL}/opps_conversion_factors_CY#{year}.csv"

      apc_csv = URI.open(apc_url, &:read)
      cf_csv = URI.open(cf_url, &:read)

      # Read each file's release_label independently — a mismatch
      # (e.g., real APC weights but stub-derived CF) would otherwise
      # silently promote stub rows to :clear confidence. If either
      # file is stub-labeled, both rows inherit the stub label so the
      # analyzer's conservative-label propagation in OppsRateProvider
      # marks the result :stub_estimate.
      apc_label = apc_csv[/#\s*release_label:\s*(\S+)/, 1] || "stub_v1"
      cf_label = cf_csv[/#\s*release_label:\s*(\S+)/, 1] || "stub_v1"

      apc_rows = Corvid::CmsOppsParser.parse_apc_weights(strip_comments(apc_csv), calendar_year: year, release_label: apc_label)
      cf_rows = Corvid::CmsOppsParser.parse_conversion_factors(strip_comments(cf_csv), calendar_year: year, release_label: cf_label)

      ActiveRecord::Base.transaction do
        Corvid::OppsApcWeight.where(calendar_year: year).delete_all
        Corvid::OppsApcWeight.insert_all(apc_rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if apc_rows.any?
        Corvid::OppsConversionFactor.where(calendar_year: year).delete_all
        Corvid::OppsConversionFactor.insert_all(cf_rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if cf_rows.any?
      end

      puts "Fetched CY #{year} from cms-fee-schedules-v1: #{apc_rows.size} APC weights, #{cf_rows.size} conversion factors (label=#{label})"
    end

    def strip_comments(csv_text)
      csv_text.lines.reject { |l| l.lstrip.start_with?("#") }.join
    end

    desc "Normalize a CMS OPPS Addendum A CSV/zip into the canonical apc_weights CSV: rake cms:opps:normalize_addendum_a[year,/path/to/addendum_a.csv,/path/to/output.csv,release_label]"
    task :normalize_addendum_a, [ :year, :input, :output, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:opps:normalize_addendum_a[year,input.csv,output.csv,release_label]" unless args[:year] && args[:input] && args[:output]
      abort "Input not found: #{args[:input]}" unless File.exist?(args[:input])

      label = args[:label] || "cms_opps_cy#{args[:year]}_final_rule"
      rows = Corvid::CmsOppsAddendumANormalizer.normalize(args[:input])
      csv = Corvid::CmsOppsAddendumANormalizer.render(rows, release_label: label)
      File.write(args[:output], csv)
      puts "Wrote #{rows.size} APC weights to #{args[:output]} (label=#{label})"
    end
  end
end
