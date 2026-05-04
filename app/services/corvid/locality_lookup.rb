# Maps ZIP codes to CMS Medicare fee schedule localities.
module Corvid
  class LocalityLookup
    def self.for_zip(zip)
      zip = zip.to_s.strip[0, 5]
      mapping[zip]
    end

    def self.mapping
      @mapping ||= ZipLocality.pluck(:zip_code, :locality).to_h
    end

    def self.clear_cache!
      @mapping = nil
    end
  end
end
