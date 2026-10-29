# frozen_string_literal: true

namespace :cms do
  namespace :labor_shares do
    desc "Import CMS OPPS/ASC labor-related shares: rake cms:labor_shares:import[/path/to/cms_labor_shares.csv]"
    task :import, [ :path ] => :environment do |_t, args|
      path = args[:path].presence || Corvid::CmsLaborShareLoader::DEFAULT_PATH.to_s
      abort "File not found: #{path}" unless File.exist?(path)

      count = Corvid::CmsLaborShareLoader.load!(path: path)
      puts "Imported #{count} CMS labor share rows from #{path} (replaced full snapshot)"
    end
  end
end
