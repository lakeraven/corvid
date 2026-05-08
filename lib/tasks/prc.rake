# frozen_string_literal: true

namespace :prc do
  desc "Import a PRC export file: rake prc:import[/path/to/export.prc,tenant_id]"
  task :import, [ :file_path, :tenant ] => :environment do |_t, args|
    abort "Usage: rake prc:import[/path/to/export.prc,tenant_id]" unless args[:file_path] && args[:tenant]
    abort "File not found: #{args[:file_path]}" unless File.exist?(args[:file_path])

    Corvid::TenantContext.with_tenant(args[:tenant]) do
      File.open(args[:file_path]) do |io|
        result = Corvid::PrcImporter.import(io, source_file: File.basename(args[:file_path]))
        puts "Imported #{result[:obligations_imported]} obligations " \
             "(#{result[:obligations_inserted]} new, #{result[:obligations_updated]} updated) " \
             "and #{result[:payments_imported]} payments for tenant #{args[:tenant]}"
      end
    end
  end

  desc "Run analyzer over every imported obligation for a tenant: rake prc:reanalyze[tenant_id]"
  task :reanalyze, [ :tenant ] => :environment do |_t, args|
    abort "Usage: rake prc:reanalyze[tenant_id]" unless args[:tenant]

    result = Corvid::PrcImporter.reanalyze(tenant: args[:tenant])
    puts "Wrote #{result[:analyses_written]} analyses for tenant #{args[:tenant]}"
  end
end
