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
  # beside it. Legacy rows may have a hash and a nil version; they still load.
  # Validation runs on save, so a new hash must name its key version.
  class PrcEligibilityDecision < ::ActiveRecord::Base
    self.table_name = "corvid_prc_eligibility_decisions"

    include TenantScoped

    validates :person_identifier, presence: true
    validates :facility_identifier, presence: true
    validates :decided_at, presence: true
    validates :as_of_date, presence: true
    validates :eligible, inclusion: { in: [ true, false ] }
    validates :verification_snapshot_key_version, presence: true, if: -> { verification_snapshot_hash.present? }
    validates :verification_snapshot_key_version, length: { maximum: 64 }, allow_nil: true

    scope :recent, -> { order(decided_at: :desc) }
    scope :for_person, ->(identifier) { where(person_identifier: identifier) }
    scope :eligible, -> { where(eligible: true) }
    scope :ineligible, -> { where(eligible: false) }
    scope :with_reason, ->(code) { where("reason_codes @> ?", [ code.to_s ].to_json) }
  end
end
