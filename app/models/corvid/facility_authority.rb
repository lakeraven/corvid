# frozen_string_literal: true

module Corvid
  # The billing vehicle behind an encounter (#546): what kind of authority
  # a facility bills under (IHS direct, 638 contract/compact, UIO, FQHC)
  # and on what basis it can claim the AIR outside its four walls.
  # Effective-dated so classification by date of service sees the
  # authority the facility actually held at the time.
  class FacilityAuthority < ::ActiveRecord::Base
    self.table_name = "corvid_facility_authorities"

    include TenantScoped

    AUTHORITY_TYPES = %w[ihs_direct contract_638 compact_638 uio fqhc other].freeze

    validates :facility_identifier, presence: true
    validates :authority_type, presence: true, inclusion: { in: AUTHORITY_TYPES }
    # An authority with no start date must never read as "held forever":
    # an undated 638 record would otherwise classify a date of service
    # from before the contract existed at 100 percent FMAP. Same rule as
    # CahFacility/AscFacility/FeeScheduleEntry, and the mirror of
    # FmapRule, where a missing effective_on means dormant.
    validates :effective_on, presence: true
    validate :expires_after_effective

    scope :in_force_on, ->(date) {
      where.not(effective_on: nil)
        .where(effective_on: ..date)
        .where("expires_on IS NULL OR expires_on >= ?", date)
    }

    def ihs_or_638?
      %w[ihs_direct contract_638 compact_638].include?(authority_type)
    end

    def in_force_on?(date)
      return false if effective_on.nil?
      effective_on <= date && (expires_on.nil? || expires_on >= date)
    end

    private

    def expires_after_effective
      return if expires_on.blank? || effective_on.blank? || expires_on >= effective_on
      errors.add(:expires_on, "must be on or after effective_on")
    end
  end
end
