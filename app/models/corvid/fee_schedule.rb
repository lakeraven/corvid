# frozen_string_literal: true

module Corvid
  class FeeSchedule < ::ActiveRecord::Base
    self.table_name = "corvid_fee_schedules"

    include TenantScoped

    validates :name, presence: true
    validates :program, presence: true
    validates :effective_date, presence: true
    validate :end_date_after_effective_date, if: -> { end_date.present? && effective_date.present? }

    scope :current, -> { where(active: true).where("effective_date IS NULL OR effective_date <= ?", Date.current) }
    scope :for_program, ->(prog) { where(program: prog) }

    def tiers
      return [] unless tiers_token.present?

      Corvid.adapter.fetch_text(tiers_token)
    rescue
      []
    end

    def discount_for_fpl(fpl_percent)
      tiers_data = read_tiers
      return 0 if tiers_data.empty?

      tiers_data.sort_by { |t| t["fpl_max"] }.each do |tier|
        return tier["discount_percent"] if fpl_percent <= tier["fpl_max"]
      end
      0
    end

    def apply_discount(amount, fpl_percent:)
      discount = discount_for_fpl(fpl_percent)
      amount * (100 - discount) / 100.0
    end

    def self.for_patient_visit(facility_identifier: nil, program:)
      scope = current.for_program(program)
      scope = scope.for_facility(facility_identifier) if facility_identifier
      scope.first
    end

    private

    def read_tiers
      return @_tiers_cache if defined?(@_tiers_cache)

      @_tiers_cache = if tiers_token.present?
        result = Corvid.adapter.fetch_text(tiers_token)
        result.is_a?(Array) ? result : []
      else
        []
      end
    rescue
      @_tiers_cache = []
    end

    def end_date_after_effective_date
      errors.add(:end_date, "must be after effective date") if end_date <= effective_date
    end
  end
end
