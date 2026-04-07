# frozen_string_literal: true

module Corvid
  class Determination < ::ActiveRecord::Base
    self.table_name = "corvid_determinations"

    include TenantScoped

    belongs_to :determinable, polymorphic: true

    enum :decision_method, {
      automated: "automated",
      staff_review: "staff_review",
      committee_review: "committee_review"
    }, prefix: :decision_method

    enum :outcome, {
      approved: "approved",
      denied: "denied",
      deferred: "deferred",
      pending_review: "pending_review"
    }

    validate :determinable_in_same_tenant
    validates :determined_by_identifier, presence: true, unless: :decision_method_automated?

    before_create :set_determined_at

    def determined_by
      Corvid.adapter.find_practitioner(determined_by_identifier) if determined_by_identifier.present?
    end

    private

    def determinable_in_same_tenant
      return unless determinable && tenant_identifier && determinable.respond_to?(:tenant_identifier)
      return if determinable.tenant_identifier == tenant_identifier

      errors.add(:determinable, "must belong to the same tenant")
    end

    def set_determined_at
      self.determined_at ||= Time.current
    end
  end
end
