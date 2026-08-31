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
    validate :expires_after_effective

    scope :in_force_on, ->(date) {
      where("effective_on IS NULL OR effective_on <= ?", date)
        .where("expires_on IS NULL OR expires_on >= ?", date)
    }

    def ihs_or_638?
      %w[ihs_direct contract_638 compact_638].include?(authority_type)
    end

    def in_force_on?(date)
      (effective_on.nil? || effective_on <= date) && (expires_on.nil? || expires_on >= date)
    end

    private

    def expires_after_effective
      return if expires_on.blank? || effective_on.blank? || expires_on >= effective_on
      errors.add(:expires_on, "must be on or after effective_on")
    end
  end
end
