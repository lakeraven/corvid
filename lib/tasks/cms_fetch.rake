# frozen_string_literal: true

require "open-uri"

namespace :cms do
  RELEASE_BASE = "https://github.com/lakeraven/corvid/releases/download/cms-fee-schedules-v1"

  # Most years follow RVU{yy}A.zip, but 2007/2008/2010 use specific
  # CMS-published revision suffixes. This mapping is the canonical
  # year → zip filename lookup.
  RELEASE_FILES = {
    2007 => "RVU07A4.zip",
    2008 => "RVU08AR.zip",
    2009 => "RVU09A.zip",
    2010 => "RVU10AR1.zip",
    2011 => "RVU11A.zip",
    2012 => "RVU12A.zip",
    2013 => "RVU13A.zip",
    2014 => "RVU14A.zip",
    2015 => "RVU15A.zip",
    2016 => "RVU16A.zip",
    2017 => "RVU17A.zip",
    2018 => "RVU18A.zip",
    2019 => "RVU19A.zip",
    2020 => "RVU20A.zip",
    2021 => "RVU21A.zip",
    2022 => "RVU22A.zip",
    2023 => "RVU23A.zip",
    2024 => "RVU24A.zip",
    2025 => "RVU25A.zip",
    2026 => "RVU26A.zip"
  }.freeze

  desc "Download and extract CMS fee schedule source for a given year: rake cms:fetch[2026]"
  task :fetch, [ :year ] => :environment do |_t, args|
    year = args[:year].to_i
    zip = RELEASE_FILES[year]
    abort "Unknown year: #{year}. Known years: #{RELEASE_FILES.keys.join(", ")}" unless zip

    base = Corvid::Engine.root.join("db/data/cms_fee_schedules")
    base.mkpath
    zip_path = base.join(zip)

    if zip_path.exist?
      puts "Already downloaded: #{zip_path}"
    else
      url = "#{RELEASE_BASE}/#{zip}"
      puts "Downloading #{url}"
      URI.open(url) { |io| zip_path.binwrite(io.read) }
      puts "Saved #{zip_path}"
    end

    # Extract into year directory so cms:import can find the CSVs.
    year_dir = base.join(year.to_s)
    year_dir.mkpath
    system("unzip", "-o", "-q", zip_path.to_s, "-d", year_dir.to_s) ||
      abort("Failed to extract #{zip_path}")
    puts "Extracted to #{year_dir}"
  end

  desc "Download and extract every available year"
  task fetch_all: :environment do
    RELEASE_FILES.keys.each do |year|
      Rake::Task["cms:fetch"].reenable
      Rake::Task["cms:fetch"].invoke(year)
    end
  end
end
