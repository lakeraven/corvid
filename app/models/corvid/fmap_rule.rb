# frozen_string_literal: true

module Corvid
  # A statutory FMAP rule as data (#546). Global reference data like the
  # CMS rate tables — not tenant-scoped. `in_force_on` is the only lens
  # classification may look through: an encounter is always classified
  # under the rules in force on its date of service, so a retrospective
  # audit reproduces historical determinations exactly.
  class FmapRule < ::ActiveRecord::Base
    self.table_name = "corvid_fmap_rules"

    # The expansion tier is this category, or any rule scoped to the
    # expansion adult group (StateMedicaidRules vocabulary) under another
    # category. Both have to go through the same gate.
    EXPANSION_CATEGORY = "fmap_90_expansion"
    EXPANSION_COVERAGE_GROUP = "expansion_adult"

    CATEGORIES = [
      "fmap_100_ihs_638",
      "fmap_100_cca",
      "fmap_100_uio",
      EXPANSION_CATEGORY,
      "fmap_regular",
      "non_medicaid"
    ].freeze

    validates :rule_key, presence: true, uniqueness: true
    validates :jurisdiction, presence: true
    validates :category, presence: true, inclusion: { in: CATEGORIES }
    RECEIVED_THROUGH_BASES = %w[facility_authority cca].freeze

    # Evidence a caller may supply, as { "supports" => kind, "ref" => token }.
    # Received-through evidence is never caller-supplied: it is the stored
    # facility authority, which the determination records by id.
    CALLER_EVIDENCE_KINDS = %w[aian_status].freeze

    validates :statutory_citation, presence: true
    # Same vocabulary as the eligibility group StateMedicaidRules and
    # AlternateResourceCheck record, so a stated group matches its rule.
    validates :coverage_group, inclusion: { in: StateMedicaidRules::GROUPS }, allow_nil: true
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

    # The expansion tier: the 90 percent category, or a rule scoped to
    # the expansion adult group under any category. Classification, its
    # best-available lens, and FmapDetermination all gate on this, so a
    # group-scoped rule cannot skip the expansion-state check by wearing
    # another category. Whether the jurisdiction has expanded is a
    # StateMedicaidRules lookup, not a property of this row.
    def expansion?
      category == EXPANSION_CATEGORY || self[:coverage_group] == EXPANSION_COVERAGE_GROUP
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

    # The evidence this rule's requirements still lack. Each requirement
    # needs its own: an AI/AN attestation entry for the AI/AN status, and
    # a stored facility authority (authority_backed) for a facility basis.
    # A CCA basis is never satisfied yet: no CareCoordinationAgreement
    # record exists to show an agreement covers the service and date.
    # (Whether the AI/AN status is verified is a match criterion, checked
    # by #matches?; this checks only that evidence for it exists.)
    def unmet_evidence(received_through_basis:, evidence:, authority_backed:)
      unmet = []
      if requires_aian && evidence.none? { |e| e["supports"] == "aian_status" }
        unmet << FmapClassificationService.missing_evidence_term(:aian_status_evidence)
      end
      if requires_received_through
        if received_through_basis.to_s == "cca"
          unmet << FmapClassificationService.missing_evidence_term(:care_coordination_agreement)
        elsif !authority_backed
          unmet << FmapClassificationService.missing_evidence_term(:received_through_evidence)
        end
      end
      unmet
    end

    # Evidence entries as string-keyed { "supports", "ref" } hashes with a
    # non-blank ref. Anything else is not evidence and is dropped, so it
    # can never satisfy a requirement.
    def self.normalize_evidence(entries)
      Array(entries).filter_map do |entry|
        next unless entry.is_a?(Hash)
        supports = (entry["supports"] || entry[:supports]).to_s
        ref = (entry["ref"] || entry[:ref]).to_s
        { "supports" => supports, "ref" => ref } if supports.present? && ref.present?
      end
    end

    private

    def expires_after_effective
      return if expires_on.blank? || effective_on.blank? || expires_on >= effective_on
      errors.add(:expires_on, "must be on or after effective_on")
    end
  end
end
