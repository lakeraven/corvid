# frozen_string_literal: true

module Corvid
  class Task < ::ActiveRecord::Base
    self.table_name = "corvid_tasks"

    include TenantScoped

    belongs_to :taskable, polymorphic: true

    enum :status, { pending: "pending", in_progress: "in_progress", completed: "completed", cancelled: "cancelled" }
    enum :priority, { asap: "asap", urgent: "urgent", routine: "routine" }, prefix: :priority

    validates :description, presence: true
    validate :taskable_in_same_tenant

    scope :incomplete, -> { where(status: %w[pending in_progress]) }
    scope :overdue, -> { incomplete.where("due_at < ?", Time.current) }
    scope :unassigned, -> { where(assignee_identifier: nil) }
    scope :for_assignee, ->(identifier) { where(assignee_identifier: identifier) }
    scope :milestones, -> { where.not(milestone_key: nil) }

    before_save :set_completed_at, if: :status_changed_to_completed?

    def assignee
      Corvid.adapter.find_practitioner(assignee_identifier) if assignee_identifier.present?
    end

    def assign_to!(practitioner_identifier)
      update!(assignee_identifier: practitioner_identifier)
    end

    def unassign!
      update!(assignee_identifier: nil)
    end

    def overdue?
      !completed? && due_at.present? && due_at < Time.current
    end

    def milestone?
      milestone_key.present?
    end

    private

    def taskable_in_same_tenant
      return unless taskable && tenant_identifier && taskable.respond_to?(:tenant_identifier)
      return if taskable.tenant_identifier == tenant_identifier

      errors.add(:taskable, "must belong to the same tenant")
    end

    def status_changed_to_completed?
      status_changed? && completed?
    end

    def set_completed_at
      self.completed_at ||= Time.current
    end
  end
end
