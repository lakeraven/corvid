# frozen_string_literal: true

module Corvid
  # Append-only history of management-approval gate actions on a PRC
  # referral (#478). One row per gate action; rows are never updated or
  # individually destroyed, so invalidating an approval preserves the
  # original approval event. checklist_version_hash binds each event to
  # the exact eligibility-checklist content it acted on, which is how
  # PrcReferral#management_approval_active? proves the approved
  # determination hasn't been edited since.
  class ManagementApprovalEvent < ::ActiveRecord::Base
    self.table_name = "corvid_management_approval_events"

    include TenantScoped

    belongs_to :prc_referral, class_name: "Corvid::PrcReferral"

    ACTIONS = %w[approved rejected invalidated].freeze

    validates :action, presence: true, inclusion: { in: ACTIONS }
    validates :actor_identifier, presence: true,
              if: -> { %w[approved rejected].include?(action) }
    validates :checklist_version_hash, presence: true

    # occurred_at is always server-set — a caller-supplied value is
    # discarded, so events cannot be back-dated.
    before_validation(on: :create) { self.occurred_at = Time.current }

    scope :chronological, -> { order(:occurred_at, :id) }

    # Persisted events are immutable: update/destroy raise
    # ActiveRecord::ReadOnlyRecord (bulk delete_all still works for
    # referral cleanup, which bypasses instance callbacks by design).
    def readonly?
      persisted?
    end
  end
end
