# frozen_string_literal: true

require "open-uri"

namespace :cms do
  namespace :ipps do
    desc "Import CMS IPPS DRG weights from a canonical CSV: rake cms:ipps:import_drg_weights[year,/path/to/drg_weights.csv,release_label]"
    task :import_drg_weights, [ :year, :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:ipps:import_drg_weights[year,/path/to/drg_weights.csv,release_label]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      label = args[:label] || "manual"
      rows = Corvid::CmsIppsParser.parse_drg_weights(
        File.read(args[:path]), fiscal_year: year, release_label: label
      )

      ActiveRecord::Base.transaction do
        Corvid::IppsDrgWeight.where(fiscal_year: year).delete_all
        Corvid::IppsDrgWeight.insert_all(rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if rows.any?
      end

      puts "Imported #{rows.size} DRG weights for FY #{year} (label=#{label}, replaced full year snapshot)"
    end

    desc "Import CMS IPPS hospital rates from a canonical CSV: rake cms:ipps:import_hospital_rates[year,/path/to/hospital_rates.csv,release_label]"
    task :import_hospital_rates, [ :year, :path, :label ] => :environment do |_t, args|
      abort "Usage: rake cms:ipps:import_hospital_rates[year,/path/to/hospital_rates.csv,release_label]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      label = args[:label] || "manual"
      rows = Corvid::CmsIppsParser.parse_hospital_rates(
        File.read(args[:path]), fiscal_year: year, release_label: label
      )

      ActiveRecord::Base.transaction do
        Corvid::IppsHospitalRate.where(fiscal_year: year).delete_all
        Corvid::IppsHospitalRate.insert_all(rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if rows.any?
      end

      puts "Imported #{rows.size} hospital rates for FY #{year} (label=#{label}, replaced full year snapshot)"
    end

    IPPS_RELEASE_BASE_URL = "https://github.com/lakeraven/corvid/releases/download/cms-fee-schedules-v1"

    desc "Fetch + import IPPS canonical CSVs from the cms-fee-schedules-v1 GitHub Release: rake cms:ipps:fetch_release[year]"
    task :fetch_release, [ :year ] => :environment do |_t, args|
      abort "Usage: rake cms:ipps:fetch_release[year]" unless args[:year]
      year = args[:year].to_i

      drg_url = "#{IPPS_RELEASE_BASE_URL}/ipps_drg_weights_FY#{year}.csv"
      hosp_url = "#{IPPS_RELEASE_BASE_URL}/ipps_hospital_rates_FY#{year}.csv"

      drg_csv = URI.open(drg_url, &:read)
      hosp_csv = URI.open(hosp_url, &:read)

      # Read the release_label from a header comment if present, else
      # default to "stub_v1" — the seed-data tag we ship today.
      label = drg_csv[/#\s*release_label:\s*(\S+)/, 1] || "stub_v1"

      drg_rows = Corvid::CmsIppsParser.parse_drg_weights(strip_comments(drg_csv), fiscal_year: year, release_label: label)
      hosp_rows = Corvid::CmsIppsParser.parse_hospital_rates(strip_comments(hosp_csv), fiscal_year: year, release_label: label)

      ActiveRecord::Base.transaction do
        Corvid::IppsDrgWeight.where(fiscal_year: year).delete_all
        Corvid::IppsDrgWeight.insert_all(drg_rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if drg_rows.any?
        Corvid::IppsHospitalRate.where(fiscal_year: year).delete_all
        Corvid::IppsHospitalRate.insert_all(hosp_rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if hosp_rows.any?
      end

      puts "Fetched FY #{year} from cms-fee-schedules-v1: #{drg_rows.size} DRG weights, #{hosp_rows.size} hospital rates (label=#{label})"
    end

    def strip_comments(csv_text)
      csv_text.lines.reject { |l| l.lstrip.start_with?("#") }.join
    end
  end
end
