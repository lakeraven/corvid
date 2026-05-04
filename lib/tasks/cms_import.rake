# frozen_string_literal: true

require "csv"

namespace :cms do
  desc "Import fee schedule for a given year: rake cms:import[2019]"
  task :import, [:year] => :environment do |_t, args|
    year = args[:year].to_i
    yy = year.to_s[-2..]
    base = Corvid::Engine.root.join("db/data/cms_fee_schedules/#{year}")

    # Find the PPRRVU file (naming varies by year)
    rvu_file = Dir.glob(base.join("PPRRVU#{yy}*.csv")).first
    gpci_file = Dir.glob(base.join("*GPCI*#{yy}*.csv")).first ||
      Dir.glob(base.join("*GPCI*#{year}*.csv")).first ||
      Dir.glob(base.join("*[Gg][Pp][Cc][Ii]*.csv")).first

    abort "No RVU file found for #{year} in #{base}" unless rvu_file
    abort "No GPCI file found for #{year} in #{base}" unless gpci_file

    puts "Importing #{year} fee schedule..."
    puts "  RVU file: #{rvu_file}"
    puts "  GPCI file: #{gpci_file}"

    # Parse GPCIs: locality → { work_gpci, pe_gpci, mp_gpci }
    gpcis = parse_gpcis(gpci_file)
    puts "  Loaded #{gpcis.size} localities from GPCI file"

    # Parse conversion factor from RVU file
    cf = parse_conversion_factor(rvu_file, year)
    puts "  Conversion factor: #{cf}"

    # Parse RVUs and insert per locality
    effective_date = Date.new(year, 1, 1)
    imported = 0

    parse_rvus(rvu_file) do |cpt, work_rvu, pe_rvu, mp_rvu|
      gpcis.each do |locality, gpci|
        Corvid::FeeScheduleEntry.upsert(
          {
            cpt_code: cpt,
            locality: locality,
            effective_date: effective_date,
            work_rvu: work_rvu,
            pe_rvu: pe_rvu,
            mp_rvu: mp_rvu,
            work_gpci: gpci[:work],
            pe_gpci: gpci[:pe],
            mp_gpci: gpci[:mp],
            conversion_factor: cf
          },
          unique_by: [:cpt_code, :locality, :effective_date]
        )
        imported += 1
      end
    end

    puts "  Imported #{imported} entries for #{year}"
  end

  desc "Import all available years"
  task import_all: :environment do
    base = Corvid::Engine.root.join("db/data/cms_fee_schedules")
    years = Dir.glob(base.join("20*")).map { |d| File.basename(d).to_i }.sort

    years.each do |year|
      Rake::Task["cms:import"].reenable
      Rake::Task["cms:import"].invoke(year)
    end
  end

  desc "Import ZIP-to-locality mapping for a given year"
  task :import_localities, [:year] => :environment do |_t, args|
    year = args[:year].to_i
    yy = year.to_s[-2..]
    base = Corvid::Engine.root.join("db/data/cms_fee_schedules/#{year}")

    loc_file = Dir.glob(base.join("#{yy}LOCCO*.csv")).first
    abort "No locality file found for #{year}" unless loc_file

    puts "Importing localities from #{loc_file}..."
    # LOCCO files have counties, not ZIPs — need separate ZIP mapping
    # For now, import carrier/locality mapping
    puts "  (ZIP-to-locality requires separate CMS file — see cms:import_zips)"
  end
end

def parse_gpcis(file)
  gpcis = {}
  started = false

  CSV.foreach(file, encoding: "iso-8859-1:utf-8", liberal_parsing: true) do |row|
    # Skip header rows until we see data (starts with a carrier number)
    if !started && row[1]&.strip&.match?(/^\d{2}$/)
      started = true
    end
    next unless started
    next if row[1].nil?

    locality = row[1].strip
    next unless locality.match?(/^\d{2}$/)

    work = row[3]&.to_f || 1.0
    pe = row[4]&.to_f || 1.0
    mp = row[5]&.to_f || 1.0

    gpcis[locality] = {work: work, pe: pe, mp: mp}
  end

  gpcis
end

def parse_conversion_factor(file, year)
  # CMS conversion factors by year (from Federal Register)
  # These are published annually — hardcoded for reliability
  cfs = {
    2007 => 37.8975, 2008 => 38.0870, 2009 => 36.0666,
    2010 => 36.0846, 2011 => 33.9764, 2012 => 34.0230,
    2013 => 34.0230, 2014 => 35.8228, 2015 => 35.7547,
    2016 => 35.8043, 2017 => 35.8887, 2018 => 35.9996,
    2019 => 36.0391, 2020 => 36.0896, 2021 => 34.8931,
    2022 => 34.6062, 2023 => 33.0607, 2024 => 32.7442,
    2025 => 32.3465, 2026 => 32.74
  }
  cfs[year] || 32.74
end

def parse_rvus(file, &block)
  header_found = false
  hcpcs_col = nil
  work_col = nil
  pe_col = nil
  mp_col = nil

  CSV.foreach(file, encoding: "iso-8859-1:utf-8", liberal_parsing: true) do |row|
    # Find header row (contains "HCPCS")
    if !header_found && row.any? { |c| c&.strip == "HCPCS" }
      header_found = true
      row.each_with_index do |col, i|
        c = col&.strip&.upcase
        hcpcs_col = i if c == "HCPCS"
        work_col = i if c == "WORK" || c&.include?("WORK") && c&.include?("RVU")
        mp_col = i if c == "MP" || (c&.start_with?("MP") && c&.include?("RVU"))
      end
      # Work RVU is typically column after HCPCS status columns
      work_col ||= 5
      pe_col = work_col + 1
      mp_col ||= work_col + 9
      next
    end
    next unless header_found

    cpt = row[hcpcs_col || 0]&.strip
    next if cpt.nil? || cpt.empty? || !cpt.match?(/^[0-9A-Z]/)

    work = row[work_col]&.to_f || 0
    pe = row[pe_col]&.to_f || 0
    mp = row[mp_col]&.to_f || 0

    next if work.zero? && pe.zero?

    block.call(cpt, work, pe, mp)
  end
end
