# frozen_string_literal: true

module Corvid
  # A life-outcome event on an AI/AN Medicaid exemption: the exemption was
  # asserted, coverage was retained through the state's process, the member
  # was erroneously disenrolled by administrative churn, an appeal was filed,
  # or coverage was reinstated.
  #
  # This is distinct from a Determination (which records a *decision*
  # outcome). It is the exemption-scoped precursor to the general
  # Corvid::CaseOutcome model (#332); when that model lands these events fold
  # into it. Kept narrow and standalone so this feature ships independently.
  #
  # Per ADR 0003, free-text notes are vault tokens (notes_token), never PHI
  # at rest.
  class ExemptionEvent < ::ActiveRecord::Base
    self.table_name = "corvid_exemption_events"

    include TenantScoped

    enum :event_type, {
      asserted: "asserted",
      coverage_retained: "coverage_retained",
      erroneously_disenrolled: "erroneously_disenrolled",
      appeal_filed: "appeal_filed",
      coverage_reinstated: "coverage_reinstated",
      revoked: "revoked",
      expired: "expired"
    }, prefix: :event

    EVENT_TYPES = event_types.keys.freeze

    belongs_to :medicaid_exemption,
               class_name: "Corvid::MedicaidExemption",
               optional: true

    validates :person_identifier, presence: true
    validates :event_type, presence: true
    validates :occurred_on, presence: true

    # Model-level isolation: a linked exemption MUST belong to the same tenant
    # AND the same person as the event. Without this, a direct create! (not just
    # the service) could link an event to another tenant's/person's exemption,
    # corrupting the audit trail. Enforced here so isolation holds at the model
    # layer, not only in MedicaidExemptionService.
    validate :linked_exemption_shares_tenant_and_person

    scope :for_person, ->(identifier) { where(person_identifier: identifier) }
    scope :of_type, ->(type) { where(event_type: type) }
    scope :chronological, -> { order(occurred_on: :asc, created_at: :asc) }

    private

    def linked_exemption_shares_tenant_and_person
      return if medicaid_exemption.nil?

      if medicaid_exemption.tenant_identifier != tenant_identifier
        errors.add(:medicaid_exemption, "belongs to a different tenant")
      end
      if medicaid_exemption.person_identifier != person_identifier
        errors.add(:medicaid_exemption, "belongs to a different person")
      end
    end
  end
end
