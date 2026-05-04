# ZIP code to CMS locality mapping.
# Imported from CMS Physician Fee Schedule Locality file.
module Corvid
  class ZipLocality < ::ActiveRecord::Base
    self.table_name = "corvid_zip_localities"

    validates :zip_code, presence: true, uniqueness: true
    validates :locality, presence: true

    scope :for_state, ->(state) { where(state: state) }
  end
end
