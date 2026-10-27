# frozen_string_literal: true

module Corvid
  # CMS ZIP code to wage area, by federal fiscal year. Urban rows use a
  # 5-digit CBSA. Rural rows use the 2-digit CMS state code. One ZIP
  # maps to one wage area within a fiscal year.
  class ZipCbsaCrosswalk < ::ActiveRecord::Base
    self.table_name = "corvid_zip_cbsa_crosswalks"

    ZIP_FORMAT = /\A[0-9]{5}\z/
    CBSA_FORMAT = /\A(?:[0-9]{5}|[0-9]{2})\z/

    validates :fiscal_year, presence: true
    validates :zip, presence: true, format: { with: ZIP_FORMAT }
    validates :cbsa, presence: true, format: { with: CBSA_FORMAT }
  end
end
