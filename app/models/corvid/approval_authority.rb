# frozen_string_literal: true

module Corvid
  # Per-tenant registry of who may approve PRC eligibility determinations
  # (#478): the PRC Director, plus delegated backup approvers (#489).
  # Actors are opaque practitioner identifiers, consistent with the
  # engine-wide no-local-identity rule (resolved for display via
  # Corvid.adapter.find_practitioner).
  #
  # The gate is progressive: until a tenant grants its first authority,
  # PrcReferral#approver_has_authority? is a no-op (bootstrap mode, same
  # pattern as the dual-control legacy no-op for blank submitters). Once
  # any authority exists for the tenant, only active grantees can approve.
  class ApprovalAuthority < ::ActiveRecord::Base
    self.table_name = "corvid_approval_authorities"

    include TenantScoped

    ROLES = %w[prc_director delegated_approver].freeze

    validates :practitioner_identifier, presence: true
    validates :role, presence: true, inclusion: { in: ROLES }

    before_validation(on: :create) { self.granted_at ||= Time.current }

    scope :active, -> { where(revoked_at: nil) }

    def self.gate_configured?
      exists?
    end

    def self.active_approver?(practitioner_identifier)
      active.exists?(practitioner_identifier: practitioner_identifier)
    end

    def active?
      revoked_at.nil?
    end

    def revoke!
      update!(revoked_at: Time.current)
    end
  end
end
