# frozen_string_literal: true

module Corvid
  # An AI/AN Medicaid exemption carried on the member record. Under HR-1
  # (2025 reconciliation) American Indians/Alaska Natives — including Urban
  # Indians and IHS beneficiaries — are exempt from Medicaid
  # community-engagement/work requirements AND from the more-frequent
  # (6-month) eligibility redeterminations beginning January 2027.
  #
  # Exemption on paper does not retain coverage on its own: exempt members
  # still lose coverage to administrative churn unless the exemption is
  # flagged, asserted, and maintained. This record is that flag.
  #
  # The status is ALWAYS sourced from a verified assertion (baseroll
  # IAL2/AAL2 verification reached through the adapter) — never self-report.
  # Rows are created by MedicaidExemptionService.assert, which records the
  # verification provenance alongside the flag.
  class MedicaidExemption < ::ActiveRecord::Base
    self.table_name = "corvid_medicaid_exemptions"

    include TenantScoped

    # The two HR-1 exemptions AI/AN status confers. Both flow from the same
    # verified status but are legally distinct, so they are tracked separately.
    enum :exemption_type, {
      work_requirement: "work_requirement",
      six_month_redetermination: "six_month_redetermination"
    }, prefix: :exemption_type

    enum :status, {
      asserted: "asserted",
      expired: "expired",
      revoked: "revoked"
    }, prefix: :status

    EXEMPTION_TYPES = exemption_types.keys.freeze

    has_many :exemption_events,
             class_name: "Corvid::ExemptionEvent",
             dependent: :nullify

    validates :person_identifier, presence: true
    validates :exemption_type, presence: true
    validates :verified_at, presence: true
    validates :verification_source, presence: true
    # At most one asserted exemption of a type per person per tenant. Enforced
    # in the DB by a partial unique index; validated here for a clean error.
    validates :exemption_type,
              uniqueness: {
                scope: [ :tenant_identifier, :person_identifier ],
                conditions: -> { status_asserted },
                message: "already has an asserted exemption for this person"
              },
              if: :status_asserted?

    scope :for_person, ->(identifier) { where(person_identifier: identifier) }
    scope :of_type, ->(type) { where(exemption_type: type) }
    scope :active, -> { status_asserted }

    # True when the exemption is asserted and not past its expiry.
    def in_effect?(as_of: Time.current)
      status_asserted? && (expires_at.nil? || expires_at > as_of)
    end
  end
end
