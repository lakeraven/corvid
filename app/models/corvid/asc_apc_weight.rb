# frozen_string_literal: true

module Corvid
  # CMS ASC APC relative weight, by calendar year. Sourced from the
  # ASC payment system Final Rule annual tables (Addendum AA). Differs
  # from OppsApcWeight: ASC weights are sometimes lower than OPPS for
  # the same APC (e.g., procedures with a device-intensive offset).
  class AscApcWeight < ::ActiveRecord::Base
    self.table_name = "corvid_asc_apc_weights"

    validates :calendar_year, presence: true
    validates :apc_code, presence: true
    validates :relative_weight, presence: true, numericality: { greater_than: 0 }

    scope :for_year, ->(year) { where(calendar_year: year) }
  end
end
