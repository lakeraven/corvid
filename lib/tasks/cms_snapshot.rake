# frozen_string_literal: true

require "zlib"

namespace :cms do
  namespace :snapshot do
    desc "Export the current CMS fee schedule data to db/seeds/cms_fee_schedules.csv.gz"
    task export: :environment do
      path = Corvid::Engine.root.join(Corvid::CmsSnapshot::DEFAULT_PATH)
      path.dirname.mkpath

      rows = 0
      Zlib::GzipWriter.open(path) do |gz|
        rows = Corvid::CmsSnapshot.export_csv(gz)
      end

      size = path.size
      puts "Wrote #{rows} rows to #{path} (#{(size / 1024.0 / 1024.0).round(1)} MB compressed)"
      puts "SHA256: #{File.open(path) { |f| Corvid::CmsSnapshot.checksum_io(f) }}"
    end

    desc "Load the bundled snapshot at db/seeds/cms_fee_schedules.csv.gz into the database"
    task load: :environment do
      path = Corvid::Engine.root.join(Corvid::CmsSnapshot::DEFAULT_PATH)
      abort "Snapshot not found at #{path}" unless path.exist?

      checksum = File.open(path) { |f| Corvid::CmsSnapshot.checksum_io(f) }
      puts "Loading snapshot from #{path}"
      puts "  SHA256: #{checksum}"

      rows = 0
      Zlib::GzipReader.open(path) do |gz|
        rows = Corvid::CmsSnapshot.import_csv(gz)
      end

      puts "Loaded #{rows} rows"
    end
  end
end
