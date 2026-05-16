# Medicare Physician Fee Schedule entry.
# Imported quarterly from CMS public data.
# No PHI — only procedure codes, localities, and rates.
module Corvid
  class FeeScheduleEntry < ::ActiveRecord::Base
    self.table_name = "corvid_fee_schedule_entries"

    validates :cpt_code, presence: true
    validates :locality, presence: true
    validates :effective_date, presence: true
    validates :cpt_code, uniqueness: { scope: [ :locality, :effective_date ] }

    scope :current, -> { where(effective_date: ..Date.current).order(effective_date: :desc) }
    scope :for_code, ->(code) { where(cpt_code: code) }
    scope :for_locality, ->(locality) { where(locality: locality) }

    def self.rate_for(cpt_code:, locality:, date: Date.current)
      for_code(cpt_code)
        .for_locality(locality)
        .where(effective_date: ..date)
        .order(effective_date: :desc)
        .first
    end

    def medicare_rate
      (work_rvu * work_gpci + pe_rvu * pe_gpci + mp_rvu * mp_gpci) * conversion_factor
    end
  end
end
