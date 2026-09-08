# frozen_string_literal: true

# #478 approval-gate hardening: an append-only history of management-approval
# gate actions (approved / rejected / invalidated), each bound to the exact
# checklist version it acted on, plus a per-tenant registry of who holds
# approval authority (PRC Director or delegated approver — groundwork for #489).
class CreateManagementApprovalEventsAndAuthorities < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_management_approval_events do |t|
      t.references :prc_referral, null: false,
                   foreign_key: { to_table: :corvid_prc_referrals }
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :action, null: false
      t.string :actor_identifier
      t.string :checklist_version_hash, null: false
      t.string :reason_token
      t.datetime :occurred_at, null: false
      t.timestamps
      t.index :tenant_identifier
    end
    add_check_constraint :corvid_management_approval_events,
      "action IN ('approved','rejected','invalidated')",
      name: "corvid_mgmt_approval_event_action_check"

    create_table :corvid_approval_authorities do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :practitioner_identifier, null: false
      t.string :role, null: false, default: "prc_director"
      t.string :granted_by_identifier
      t.datetime :granted_at, null: false
      t.datetime :revoked_at
      t.timestamps
      t.index [ :tenant_identifier, :practitioner_identifier ],
              name: "idx_corvid_approval_authorities_on_tenant_practitioner"
    end
    add_check_constraint :corvid_approval_authorities,
      "role IN ('prc_director','delegated_approver')",
      name: "corvid_approval_authority_role_check"
  end
end
