# frozen_string_literal: true

module Corvid
  # Output object of FmapClassificationService (#546): one row per
  # classification, carrying the applied rule citations, the evidence
  # chain, and the best-available category with what evidence is missing
  # to reach it — the misclassification finding in structured form.
  #
  # Immutable once a claim references it (same validation idiom as
  # CurrencyImmutable): a stale audit re-export must never quietly
  # disagree with what the claim was assembled from. Corrections append
  # via #supersede_with!, which links the replacement to the original.
  class FmapDetermination < ::ActiveRecord::Base
    self.table_name = "corvid_fmap_determinations"

    include TenantScoped

    # Raised when a correction is appended to a row that already has one:
    # a chain has exactly one current row.
    class AlreadySupersededError < StandardError; end

    # What a correction carries forward from the row it replaces.
    CARRIED_FIELDS = %w[
      encounter_identifier person_identifier facility_identifier date_of_service jurisdiction
      category fmap_percent rule_key rule_citations evidence_refs aian_verified
      received_through_basis facility_authority_id authority_type coverage_group
      best_available_category best_available_rule_key missing_evidence
      state_share_delta_cents determination_reason
    ].freeze
    # The applied rule's outcome: not carried when a correction changes the rule.
    APPLIED_RULE_FIELDS = %w[
      category fmap_percent rule_key rule_citations state_share_delta_cents determination_reason
    ].freeze
    # The decided fields; writing any of them re-runs the rule and evidence checks.
    DECISION_FIELDS = %w[
      category fmap_percent rule_key rule_citations evidence_refs aian_verified
      received_through_basis facility_authority_id authority_type coverage_group
      date_of_service jurisdiction facility_identifier
    ].freeze

    belongs_to :superseded_by, class_name: "Corvid::FmapDetermination", optional: true
    belongs_to :facility_authority, class_name: "Corvid::FacilityAuthority", optional: true

    validates :encounter_identifier, presence: true
    validates :date_of_service, presence: true
    validates :jurisdiction, presence: true
    validates :determined_at, presence: true
    # "undetermined" is a determination outcome, not a statutory rule
    # category: it records that no in-force rule applied, or that a 100
    # percent tier was refused for want of evidence.
    CATEGORIES = (FmapRule::CATEGORIES + [ FmapClassificationService::UNDETERMINED ]).freeze

    validates :category, presence: true, inclusion: { in: CATEGORIES }
    validates :received_through_basis, inclusion: { in: FmapRule::RECEIVED_THROUGH_BASES }, allow_nil: true
    validates :authority_type, inclusion: { in: FacilityAuthority::AUTHORITY_TYPES }, allow_nil: true
    validates :coverage_group, inclusion: { in: FmapClassificationService::COVERAGE_GROUPS }, allow_nil: true
    validates :determination_reason, inclusion: { in: FmapClassificationService::REASONS }, allow_nil: true
    validate :immutable_once_claimed
    validate :supersession_is_final
    # Checked when the decided fields are written, not when only the
    # supersession link is, so a later edit to rule data cannot block
    # appending a correction to an old row.
    validate :cites_applied_rule, if: :decision_changed?
    validate :evidence_backs_hundred_percent, if: :decision_changed?
    validate :authority_is_own_facilitys, if: :decision_changed?

    scope :current, -> { where(superseded_by_id: nil) }
    scope :misclassified, -> {
      where.not(best_available_category: nil).where("best_available_category <> category")
    }
    scope :for_encounter, ->(identifier) { where(encounter_identifier: identifier) }

    def claimed?
      claim_reference.present?
    end

    def misclassification_gap?
      best_available_category.present? && best_available_category != category
    end

    # Append-only correction: creates a replacement row carrying forward
    # the encounter context, links it back, and leaves this row intact.
    # A correction that names another rule (or category) takes that
    # rule's category, percent and citation instead of carrying the old
    # ones, and drops the old rule's delta and reason. A row is
    # superseded once; correct the current row, not an old one.
    def supersede_with!(**attrs)
      attrs = attrs.stringify_keys
      replacement = nil
      transaction do
        lock!
        raise AlreadySupersededError, "determination #{id} is already superseded" if superseded_by_id.present?

        carried = slice(*CARRIED_FIELDS)
        if attrs.key?("rule_key") || attrs.key?("category")
          carried = carried.except(*APPLIED_RULE_FIELDS)
          carried.merge!(applied_rule_fields(attrs["rule_key"])) if attrs.key?("rule_key")
        end
        replacement = self.class.create!(carried.merge(attrs).merge("determined_at" => Time.current))
        update!(superseded_by_id: replacement.id)
      end
      replacement
    end

    private

    def applied_rule_fields(key)
      return { "rule_key" => nil, "fmap_percent" => nil, "rule_citations" => [] } if key.nil?

      rule = FmapRule.find_by(rule_key: key)
      return { "rule_key" => key } if rule.nil?

      {
        "rule_key" => key,
        "category" => rule.category,
        "fmap_percent" => rule.fmap_percent,
        "rule_citations" => [ rule.statutory_citation ]
      }
    end

    def decision_changed?
      new_record? || DECISION_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
    end

    def applied_rule
      return nil if rule_key.blank?
      @applied_rule = nil if @applied_rule&.rule_key != rule_key
      @applied_rule ||= FmapRule.find_by(rule_key: rule_key)
    end

    # The row cites exactly the rule it was decided under, and that rule
    # was in force for the jurisdiction on the date of service. An
    # undetermined row cites nothing.
    def cites_applied_rule
      if category == FmapClassificationService::UNDETERMINED
        errors.add(:rule_key, "must be blank when undetermined") if rule_key.present?
        errors.add(:rule_citations, "must be empty when undetermined") if rule_citations.present?
        return
      end

      rule = applied_rule
      if rule.nil?
        errors.add(:rule_key, "must name the FMAP rule the category was applied from")
        return
      end

      errors.add(:category, "must be the category of rule #{rule_key}") unless rule.category == category
      errors.add(:fmap_percent, "must be the percent of rule #{rule_key}") unless rule.fmap_percent == fmap_percent
      errors.add(:rule_citations, "must cite rule #{rule_key}") unless rule_citations == [ rule.statutory_citation ]
      in_force = date_of_service && jurisdiction &&
                 FmapRule.in_force_on(date_of_service).for_jurisdiction(jurisdiction).exists?(rule.id)
      errors.add(:rule_key, "must be in force for the jurisdiction on the date of service") unless in_force
    end

    # Backstop for the service rule: a persisted 100 percent
    # determination rests on the applied rule's own evidence, whether it
    # was written by classification or by a hand-entered correction.
    def evidence_backs_hundred_percent
      return unless category.to_s.start_with?("fmap_100")

      evidence = FmapRule.normalize_evidence(evidence_refs)
      if evidence.empty?
        errors.add(:evidence_refs, "must name the evidence a 100 percent determination rests on")
        return
      end

      rule = applied_rule
      return if rule.nil? # cites_applied_rule reports it

      authority = backing_authority
      unmet = rule.unmet_evidence(received_through_basis: received_through_basis, evidence: evidence,
                                  authority_backed: authority.present?)
      unless rule.matches?(facility_authority_type: authority&.authority_type, aian_verified: aian_verified,
                           received_through_basis: received_through_basis, coverage_group: coverage_group)
        unmet << "rule_criteria"
      end
      return if unmet.empty?

      errors.add(:evidence_refs, "lacks #{unmet.uniq.join(', ')} for rule #{rule_key}")
    end

    # For a facility-authority basis: the stored, same-tenant authority
    # the row names, in force on the date of service and of the recorded
    # type. Nil when the row's basis is not backed by one.
    def backing_authority
      return nil unless received_through_basis == "facility_authority"

      authority = facility_authority
      return nil if authority.nil? || !authority.in_force_on?(date_of_service)
      return nil unless authority_type == authority.authority_type
      return nil unless authority.facility_identifier == facility_identifier
      authority
    end

    # A named authority is one this tenant holds, for this row's facility,
    # whatever the category: an audit row never points across either.
    def authority_is_own_facilitys
      return if facility_authority_id.nil?
      authority = facility_authority
      unless authority && authority.facility_identifier == facility_identifier
        errors.add(:facility_authority_id, "must be an authority of this facility in the current tenant")
        return
      end
      errors.add(:authority_type, "must be the type of the named authority") unless authority_type == authority.authority_type
    end

    def supersession_is_final
      return unless persisted? && superseded_by_id_was.present? && will_save_change_to_superseded_by_id?
      errors.add(:superseded_by_id, "cannot change once set")
    end

    def immutable_once_claimed
      return unless persisted? && claim_reference_was.present?
      illegal = changes.keys - %w[superseded_by_id updated_at]
      return if illegal.empty?
      errors.add(
        :base,
        "determination is immutable once referenced by a claim " \
        "(#{claim_reference_was}); corrections must append via supersede_with!"
      )
    end
  end
end
