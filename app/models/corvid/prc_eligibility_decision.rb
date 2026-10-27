# frozen_string_literal: true

module Corvid
  # Persistent record of a single TribalEligibilityService decision. One row
  # per `decide` call, captured atomically with the decision itself so that
  # every eligibility verification produces an audit-defensible artifact.
  #
  # Reason codes are stable enum strings (see TribalEligibilityService for
  # the canonical list). Provider source + confidence are captured for
  # provenance. verification_snapshot_hash is an HMAC-SHA256 of the adapter
  # responses under a host-supplied key (ADR 0008). The key version is stored
  # beside it. Both columns are write-once at create: on a persisted row, any
  # change to either is invalid, with the error on verification_snapshot_hash.
  # A just-inserted object whose stored columns are both blank may still
  # receive them before it is reloaded. Changing the key version without the
  # hash also errors on verification_snapshot_key_version. A key version
  # requires a hash. The presence check on the version applies only when the
  # hash is being set or changed, so a legacy row can still be updated on
  # other columns. The version is at most
  # SnapshotFingerprint::MAX_VERSION_LENGTH characters.
  class PrcEligibilityDecision < ::ActiveRecord::Base
    self.table_name = "corvid_prc_eligibility_decisions"

    include TenantScoped

    validates :person_identifier, presence: true
    validates :facility_identifier, presence: true
    validates :decided_at, presence: true
    validates :as_of_date, presence: true
    validates :eligible, inclusion: { in: [ true, false ] }

    # Adapters::Base::TRIBAL_CONFIDENCE_VALUES. Null when enrolled is not exactly true or false.
    # Same set as corvid_prc_eligibility_decisions_provider_confidence_check (ADR 0002).
    PROVIDER_CONFIDENCES = %w[verified stale unavailable].freeze
    validates :provider_confidence, inclusion: { in: PROVIDER_CONFIDENCES }, allow_nil: true
    validates :verification_snapshot_key_version,
              presence: true,
              if: -> { verification_snapshot_hash.present? && will_save_change_to_verification_snapshot_hash? }
    validates :verification_snapshot_key_version,
              length: { maximum: SnapshotFingerprint::MAX_VERSION_LENGTH },
              allow_nil: true
    validate :verification_snapshot_key_version_requires_hash
    validate :verification_snapshot_fingerprint_write_once, if: :persisted?

    scope :recent, -> { order(decided_at: :desc) }
    scope :for_person, ->(identifier) { where(person_identifier: identifier) }
    scope :eligible, -> { where(eligible: true) }
    scope :ineligible, -> { where(eligible: false) }
    scope :with_reason, ->(code) { where("reason_codes @> ?", [ code.to_s ].to_json) }

    private

    def verification_snapshot_key_version_requires_hash
      return if verification_snapshot_key_version.blank?
      return if verification_snapshot_hash.present?

      errors.add(:verification_snapshot_key_version, "requires a verification snapshot hash")
    end

    def verification_snapshot_fingerprint_write_once
      return unless verification_snapshot_fingerprint_changing?
      return if initial_fingerprint_on_just_created_row?

      errors.add(:verification_snapshot_hash, "cannot change once recorded")
      return if will_save_change_to_verification_snapshot_hash?

      errors.add(
        :verification_snapshot_key_version,
        "can only be set or changed when the verification snapshot hash changes"
      )
    end

    # create! leaves previously_new_record? set until reload or the next save.
    # That object may still be given its first fingerprint. A reloaded row,
    # or one that already stored either column, may not.
    def initial_fingerprint_on_just_created_row?
      previously_new_record? &&
        verification_snapshot_hash_in_database.blank? &&
        verification_snapshot_key_version_in_database.blank?
    end

    def verification_snapshot_fingerprint_changing?
      will_save_change_to_verification_snapshot_hash? ||
        will_save_change_to_verification_snapshot_key_version?
    end
  end
end
