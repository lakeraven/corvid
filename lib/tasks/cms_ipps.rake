# frozen_string_literal: true

namespace :cms do
  namespace :ipps do
    desc "Import CMS IPPS DRG weights from a canonical CSV: rake cms:ipps:import_drg_weights[year,/path/to/drg_weights.csv]"
    task :import_drg_weights, [ :year, :path ] => :environment do |_t, args|
      abort "Usage: rake cms:ipps:import_drg_weights[year,/path/to/drg_weights.csv]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      rows = Corvid::CmsIppsParser.parse_drg_weights(File.read(args[:path]), fiscal_year: args[:year].to_i)

      ActiveRecord::Base.transaction do
        # Replace-by-(fy, drg) so re-runs converge rather than dup-erroring.
        rows.each do |attrs|
          Corvid::IppsDrgWeight
            .where(fiscal_year: attrs[:fiscal_year], drg_code: attrs[:drg_code])
            .delete_all
          Corvid::IppsDrgWeight.create!(attrs)
        end
      end

      puts "Imported #{rows.size} DRG weights for FY #{args[:year]}"
    end

    desc "Import CMS IPPS hospital rates from a canonical CSV: rake cms:ipps:import_hospital_rates[year,/path/to/hospital_rates.csv]"
    task :import_hospital_rates, [ :year, :path ] => :environment do |_t, args|
      abort "Usage: rake cms:ipps:import_hospital_rates[year,/path/to/hospital_rates.csv]" unless args[:year] && args[:path]
      abort "File not found: #{args[:path]}" unless File.exist?(args[:path])

      rows = Corvid::CmsIppsParser.parse_hospital_rates(File.read(args[:path]), fiscal_year: args[:year].to_i)

      ActiveRecord::Base.transaction do
        rows.each do |attrs|
          Corvid::IppsHospitalRate
            .where(fiscal_year: attrs[:fiscal_year], locality: attrs[:locality])
            .delete_all
          Corvid::IppsHospitalRate.create!(attrs)
        end
      end

      puts "Imported #{rows.size} hospital rates for FY #{args[:year]}"
    end
  end
end
