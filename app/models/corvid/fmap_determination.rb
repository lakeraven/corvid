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

    belongs_to :superseded_by, class_name: "Corvid::FmapDetermination", optional: true

    validates :encounter_identifier, presence: true
    validates :date_of_service, presence: true
    validates :jurisdiction, presence: true
    validates :determined_at, presence: true
    validates :category, presence: true, inclusion: { in: FmapRule::CATEGORIES }
    validate :immutable_once_claimed

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
    def supersede_with!(**attrs)
      replacement = nil
      transaction do
        replacement = self.class.create!(
          slice(
            :encounter_identifier, :person_identifier, :facility_identifier,
            :date_of_service, :jurisdiction, :category, :fmap_percent, :rule_key,
            :rule_citations, :evidence_refs, :aian_verified, :received_through_basis,
            :coverage_group, :best_available_category, :best_available_rule_key,
            :missing_evidence, :state_share_delta_cents
          ).merge(attrs.stringify_keys).merge("determined_at" => Time.current)
        )
        update!(superseded_by_id: replacement.id)
      end
      replacement
    end

    private

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
