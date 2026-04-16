# frozen_string_literal: true

module Corvid
  class Task < ::ActiveRecord::Base
    self.table_name = "corvid_tasks"

    include TenantScoped

    belongs_to :taskable, polymorphic: true

    enum :status, { pending: "pending", in_progress: "in_progress", completed: "completed", cancelled: "cancelled", on_hold: "on_hold" }
    enum :priority, { routine: "routine", urgent: "urgent", asap: "asap", stat: "stat" }, prefix: :priority

    validates :description, presence: true
    validate :taskable_in_same_tenant

    scope :incomplete, -> { where(status: %w[pending in_progress]) }
    scope :overdue, -> { incomplete.where("due_at < ?", Time.current) }
    scope :unassigned, -> { where(assignee_identifier: nil) }
    scope :for_assignee, ->(identifier) { where(assignee_identifier: identifier) }
    scope :due_soon, ->(days = 7) { incomplete.where("due_at <= ?", days.days.from_now) }
    scope :milestones, -> { where.not(milestone_key: nil) }
    scope :required_milestones, -> { milestones.where(required: true) }

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

    # FHIR status mapping
    FHIR_STATUS_MAP = {
      "pending" => "requested",
      "in_progress" => "in-progress",
      "completed" => "completed",
      "cancelled" => "cancelled",
      "on_hold" => "on-hold"
    }.freeze

    FHIR_STATUS_REVERSE_MAP = FHIR_STATUS_MAP.invert.transform_values { |v| v.tr("-", "_") }.freeze

    def incomplete?
      !completed? && !cancelled?
    end

    def overdue?
      incomplete? && due_at.present? && due_at < Time.current
    end

    def milestone?
      milestone_key.present?
    end

    def fhir_status
      FHIR_STATUS_MAP[status.to_s] || status.to_s
    end

    def to_fhir
      {
        resourceType: "Task",
        id: id&.to_s,
        status: fhir_status,
        intent: "order",
        priority: priority,
        description: description,
        focus: taskable_type.present? ? { reference: "#{fhir_taskable_type}/#{taskable_id}" } : nil,
        owner: assignee_identifier.present? ? { reference: "Practitioner/#{assignee_identifier}" } : nil,
        executionPeriod: due_at.present? ? { end: due_at.to_date.iso8601 } : nil,
        authoredOn: created_at&.iso8601,
        lastModified: updated_at&.iso8601
      }.compact
    end

    private

    def fhir_taskable_type
      case taskable_type
      when "Corvid::Case" then "EpisodeOfCare"
      when "Corvid::PrcReferral" then "ServiceRequest"
      else taskable_type
      end
    end

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
