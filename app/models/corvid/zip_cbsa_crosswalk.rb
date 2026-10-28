# frozen_string_literal: true

module Corvid
  # CMS ZIP code to wage area, by federal fiscal year. Urban rows use a
  # 5-digit CBSA. Rural rows use the 2-digit CMS state code. One ZIP
  # maps to one wage area within a fiscal year.
  class ZipCbsaCrosswalk < ::ActiveRecord::Base
    self.table_name = "corvid_zip_cbsa_crosswalks"

    ZIP_FORMAT = /\A[0-9]{5}\z/
    CBSA_FORMAT = /\A(?:[0-9]{5}|[0-9]{2})\z/

    # First key of pg_advisory_xact_lock(int, int). The fiscal year is
    # the second key, so imports of one year serialize and other years
    # do not share the lock.
    ADVISORY_LOCK_NAMESPACE = 371

    validates :fiscal_year, presence: true, inclusion: { in: 2000..2100 }
    validates :zip, presence: true, format: { with: ZIP_FORMAT }
    validates :cbsa, presence: true, format: { with: CBSA_FORMAT }

    def self.lock_fiscal_year!(year)
      sql = sanitize_sql_array([
        "SELECT pg_advisory_xact_lock(?, ?)",
        ADVISORY_LOCK_NAMESPACE,
        year
      ])
      with_connection do |connection|
        result = connection.execute(sql, "ZIP CBSA fiscal year lock")
        result.clear if result.respond_to?(:clear)
      end
    end
  end
end
