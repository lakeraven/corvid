# frozen_string_literal: true

namespace :cms do
  namespace :ipps do
    desc "Import CMS IPPS DRG weights from a canonical CSV: rake cms:ipps:import_drg_weights[year,/path/to/drg_weights.csv]"
    task :import_drg_weights, [ :year, :path ] => :environment do |_t, args|
      abort "Usage: rake cms:ipps:import_drg_weights[year,/path/to/drg_weights.csv]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      rows = Corvid::CmsIppsParser.parse_drg_weights(File.read(args[:path]), fiscal_year: year)

      ActiveRecord::Base.transaction do
        # Wipe the entire fiscal year first so the imported file is the
        # complete, authoritative snapshot. A corrected CMS file that
        # removes a DRG must propagate as a removal — replace-by-(fy, drg)
        # alone would leave the stale row and the rate provider would
        # keep using it.
        Corvid::IppsDrgWeight.where(fiscal_year: year).delete_all
        Corvid::IppsDrgWeight.insert_all(rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if rows.any?
      end

      puts "Imported #{rows.size} DRG weights for FY #{year} (replaced full year snapshot)"
    end

    desc "Import CMS IPPS hospital rates from a canonical CSV: rake cms:ipps:import_hospital_rates[year,/path/to/hospital_rates.csv]"
    task :import_hospital_rates, [ :year, :path ] => :environment do |_t, args|
      abort "Usage: rake cms:ipps:import_hospital_rates[year,/path/to/hospital_rates.csv]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      year = args[:year].to_i
      rows = Corvid::CmsIppsParser.parse_hospital_rates(File.read(args[:path]), fiscal_year: year)

      ActiveRecord::Base.transaction do
        # Same full-FY-replace semantic as DRG weights: the imported
        # file is the authoritative snapshot, removed localities must
        # propagate as removals.
        Corvid::IppsHospitalRate.where(fiscal_year: year).delete_all
        Corvid::IppsHospitalRate.insert_all(rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) }) if rows.any?
      end

      puts "Imported #{rows.size} hospital rates for FY #{year} (replaced full year snapshot)"
    end
  end
end
