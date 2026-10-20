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
  # beside it. A key version requires a hash. The presence check on
  # verification_snapshot_key_version applies only when the hash is being set
  # or changed, so legacy rows (hash, nil version) can be updated. On a
  # persisted row the version may be set or changed only in the same save
  # that sets or changes the hash. Once a keyed fingerprint is recorded (the
  # stored key version is present), neither the hash nor the key version may
  # change. Legacy rows (stored version nil) may still gain a new hash and
  # version together.
  class PrcEligibilityDecision < ::ActiveRecord::Base
    self.table_name = "corvid_prc_eligibility_decisions"

    include TenantScoped

    validates :person_identifier, presence: true
    validates :facility_identifier, presence: true
    validates :decided_at, presence: true
    validates :as_of_date, presence: true
    validates :eligible, inclusion: { in: [ true, false ] }
    validates :verification_snapshot_key_version,
              presence: true,
              if: -> { verification_snapshot_hash.present? && will_save_change_to_verification_snapshot_hash? }
    validates :verification_snapshot_key_version,
              length: { maximum: SnapshotFingerprint::MAX_VERSION_LENGTH },
              allow_nil: true
    validate :verification_snapshot_key_version_requires_hash
    validate :verification_snapshot_key_version_changes_with_hash, if: :persisted?
    validate :verification_snapshot_fingerprint_immutable_once_keyed, if: :persisted?

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

    def verification_snapshot_key_version_changes_with_hash
      return unless will_save_change_to_verification_snapshot_key_version?
      return if will_save_change_to_verification_snapshot_hash?

      errors.add(
        :verification_snapshot_key_version,
        "can only be set or changed when the verification snapshot hash changes"
      )
    end

    def verification_snapshot_fingerprint_immutable_once_keyed
      return if verification_snapshot_key_version_in_database.blank?
      return unless verification_snapshot_fingerprint_changing?

      errors.add(
        :verification_snapshot_hash,
        "cannot change once a keyed fingerprint is recorded"
      )
    end

    def verification_snapshot_fingerprint_changing?
      will_save_change_to_verification_snapshot_hash? ||
        will_save_change_to_verification_snapshot_key_version?
    end
  end
end
