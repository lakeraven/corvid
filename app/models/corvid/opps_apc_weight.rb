# frozen_string_literal: true

module Corvid
  # CMS OPPS APC relative weight, by calendar year. Sourced from the
  # OPPS Final Rule annual tables (Addendum B / Addendum A).
  class OppsApcWeight < ::ActiveRecord::Base
    self.table_name = "corvid_opps_apc_weights"

    validates :calendar_year, presence: true
    validates :apc_code, presence: true
    validates :relative_weight, presence: true, numericality: { greater_than: 0 }

    scope :for_year, ->(year) { where(calendar_year: year) }
  end
end
