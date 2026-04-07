# frozen_string_literal: true

module Corvid
  class FeeSchedule < ::ActiveRecord::Base
    self.table_name = "corvid_fee_schedules"

    include TenantScoped

    validates :name, presence: true

    scope :current, -> { where(active: true).where("effective_date IS NULL OR effective_date <= ?", Date.current) }
  end
end
