# frozen_string_literal: true

module Corvid
  # Persistent record of a single TribalEligibilityService decision. One row
  # per `decide` call, captured atomically with the decision itself so that
  # every eligibility verification produces an audit-defensible artifact.
  #
  # Reason codes are stable enum strings (see TribalEligibilityService for
  # the canonical list). Provider source + confidence are captured for
  # provenance. The verification_snapshot_hash lets auditors confirm a
  # later re-verification used the same upstream data.
  class PrcEligibilityDecision < ::ActiveRecord::Base
    self.table_name = "corvid_prc_eligibility_decisions"

    include TenantScoped

    validates :person_identifier, presence: true
    validates :facility_identifier, presence: true
    validates :decided_at, presence: true
    validates :as_of_date, presence: true
    validates :eligible, inclusion: { in: [ true, false ] }

    scope :recent, -> { order(decided_at: :desc) }
    scope :for_person, ->(identifier) { where(person_identifier: identifier) }
    scope :eligible, -> { where(eligible: true) }
    scope :ineligible, -> { where(eligible: false) }
    scope :with_reason, ->(code) { where("reason_codes @> ?", [ code.to_s ].to_json) }
  end
end
