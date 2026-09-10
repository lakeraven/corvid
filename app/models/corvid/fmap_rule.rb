# frozen_string_literal: true

module Corvid
  # A statutory FMAP rule as data (#546). Global reference data like the
  # CMS rate tables — not tenant-scoped. `in_force_on` is the only lens
  # classification may look through: an encounter is always classified
  # under the rules in force on its date of service, so a retrospective
  # audit reproduces historical determinations exactly.
  class FmapRule < ::ActiveRecord::Base
    self.table_name = "corvid_fmap_rules"

    CATEGORIES = %w[
      fmap_100_ihs_638
      fmap_100_cca
      fmap_100_uio
      fmap_90_expansion
      fmap_regular
      non_medicaid
    ].freeze

    validates :rule_key, presence: true, uniqueness: true
    validates :jurisdiction, presence: true
    validates :category, presence: true, inclusion: { in: CATEGORIES }
    validates :statutory_citation, presence: true
    validate :expires_after_effective

    scope :in_force_on, ->(date) {
      where.not(effective_on: nil)
        .where(effective_on: ..date)
        .where("expires_on IS NULL OR expires_on >= ?", date)
    }
    scope :for_jurisdiction, ->(state) { where(jurisdiction: [ "US", state.to_s ].uniq) }
    scope :dormant, -> { where(effective_on: nil) }

    def dormant?
      effective_on.nil?
    end

    # The tiers that must rest on a persisted evidence chain before
    # classification may grant them.
    def hundred_percent?
      category.to_s.start_with?("fmap_100") || fmap_percent == 100
    end

    def matches?(facility_authority_type:, aian_verified:, received_through_basis:, coverage_group: nil)
      return false if facility_authority_types.any? && !facility_authority_types.include?(facility_authority_type.to_s)
      return false if requires_aian && !aian_verified
      return false if requires_received_through && received_through_basis.blank?
      return false if received_through_bases.any? && !received_through_bases.include?(received_through_basis.to_s)
      return false if self[:coverage_group].present? && self[:coverage_group] != coverage_group.to_s
      true
    end

    # Deterministic selection order: higher federal share wins; a rule
    # scoped to specific facility types beats a catch-all; rule_key breaks
    # any remaining tie so two runs can never disagree.
    def specificity
      [ fmap_percent || -1, facility_authority_types.length, rule_key ]
    end

    private

    def expires_after_effective
      return if expires_on.blank? || effective_on.blank? || expires_on >= effective_on
      errors.add(:expires_on, "must be on or after effective_on")
    end
  end
end
