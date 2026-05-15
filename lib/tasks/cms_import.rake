# frozen_string_literal: true

namespace :cms do
  desc "Import fee schedule for a given year: rake cms:import[2019]"
  task :import, [ :year ] => :environment do |_t, args|
    year = args[:year].to_i
    base = Corvid::Engine.root.join("db/data/cms_fee_schedules/#{year}").to_s

    rvu_file = Corvid::CmsFeeScheduleParser.find_rvu_file(base, year)
    gpci_file = Corvid::CmsFeeScheduleParser.find_gpci_file(base, year)

    abort "No RVU file found for #{year} in #{base}" unless rvu_file
    abort "No GPCI file found for #{year} in #{base}" unless gpci_file

    puts "Importing #{year} fee schedule..."
    puts "  RVU file: #{rvu_file}"
    puts "  GPCI file: #{gpci_file}"

    gpcis = Corvid::CmsFeeScheduleParser.parse_gpcis(gpci_file)
    puts "  Loaded #{gpcis.size} localities from GPCI file"

    cf = Corvid::CmsFeeScheduleParser.conversion_factor(year)
    puts "  Conversion factor: #{cf}"

    effective_date = Date.new(year, 1, 1)
    imported = 0

    Corvid::CmsFeeScheduleParser.parse_rvus(rvu_file) do |cpt, work_rvu, pe_rvu, mp_rvu|
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
          unique_by: [ :cpt_code, :locality, :effective_date ]
        )
        imported += 1
      end
    end

    # Record provenance: which CMS source files produced this year's data,
    # the SHA256 of the combined source bytes, and which parser version
    # ingested it. Lets PrcOverpaymentAnalyzer and audit consumers answer
    # "where did this rate come from?" without re-reading source files.
    source_checksum = File.open(rvu_file) do |rvu_io|
      rvu_digest = Corvid::CmsSnapshot.checksum_io(rvu_io)
      gpci_digest = File.open(gpci_file) { |gp| Corvid::CmsSnapshot.checksum_io(gp) }
      Digest::SHA256.hexdigest(rvu_digest + gpci_digest)
    end

    Corvid::CmsFeeScheduleRelease.upsert(
      {
        year: year,
        cms_release_tag: File.basename(rvu_file, ".csv"),
        source_checksum_sha256: source_checksum,
        parser_version: Corvid::CmsSnapshot.parser_version,
        ingested_at: Time.current,
        row_count: Corvid::FeeScheduleEntry.where(effective_date: effective_date).count
      },
      unique_by: :year
    )

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
  task :import_localities, [ :year ] => :environment do |_t, args|
    year = args[:year].to_i
    yy = year.to_s[-2..]
    base = Corvid::Engine.root.join("db/data/cms_fee_schedules/#{year}")

    loc_file = Dir.glob(base.join("#{yy}LOCCO*.csv")).first
    abort "No locality file found for #{year}" unless loc_file

    puts "Importing localities from #{loc_file}..."
    puts "  (ZIP-to-locality requires separate CMS file — see cms:import_zips)"
  end
end
