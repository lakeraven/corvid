# frozen_string_literal: true

# 42 CFR 136.61: PRC is payer of last resort. "coordinated" records that
# alternate coverage is active and coordination of benefits is complete,
# which is a determination — distinct from "enrolled", where coordination
# is still open. ADR 0002 stores that status as a string and rejects any
# other value with a CHECK constraint, so the constraint has to grow with
# the enum or the row cannot be saved.
class AddCoordinatedStatusToAlternateResourceChecks < ActiveRecord::Migration[8.1]
  STATUSES = %w[
    not_checked checking enrolled not_enrolled
    denied exhausted pending_enrollment coordinated
  ].freeze

  def up
    remove_check_constraint :corvid_alternate_resource_checks, name: "corvid_arc_status_check"
    add_check_constraint :corvid_alternate_resource_checks,
      "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_arc_status_check"
  end

  def down
    # Closest prior status: the coverage is real, but the coordination
    # outcome is no longer representable.
    execute <<~SQL.squish
      UPDATE corvid_alternate_resource_checks
      SET status = 'enrolled'
      WHERE status = 'coordinated'
    SQL
    remove_check_constraint :corvid_alternate_resource_checks, name: "corvid_arc_status_check"
    old_statuses = STATUSES - %w[coordinated]
    add_check_constraint :corvid_alternate_resource_checks,
      "status IN (#{old_statuses.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_arc_status_check"
  end
end
