# frozen_string_literal: true

# Initial Corvid schema. Per ADR 0002, all tables are prefixed `corvid_`,
# include tenant_identifier (NOT NULL) and facility_identifier (nullable),
# use string enums with CHECK constraints, and store identifiers as strings
# (per ADR 0001). Per ADR 0003, no PHI columns — only opaque tokens.
class CreateCorvidSchema < ActiveRecord::Migration[8.1]
  CASE_STATUSES = %w[active inactive closed].freeze
  CASE_LIFECYCLE = %w[intake active_followup closure closed].freeze
  PROGRAM_TYPES = %w[immunization sti tb neonatal lead hep_b communicable_disease].freeze

  PRC_STATUSES = %w[
    draft submitted eligibility_review alternate_resource_review
    priority_assignment committee_review exception_review
    authorized denied deferred cancelled
  ].freeze

  TASK_STATUSES = %w[pending in_progress completed cancelled].freeze
  TASK_PRIORITIES = %w[asap urgent routine].freeze

  CARE_TEAM_STATUSES = %w[active inactive].freeze

  COMMITTEE_DECISIONS = %w[pending approved denied deferred modified].freeze

  DETERMINATION_DECISION_METHODS = %w[automated staff_review committee_review].freeze
  DETERMINATION_OUTCOMES = %w[approved denied deferred pending_review].freeze

  ALT_RESOURCE_TYPES = %w[
    medicare_a medicare_b medicare_d medicaid va_benefits
    private_insurance workers_comp auto_insurance liability_coverage
    state_program tribal_program charity_care
  ].freeze
  ALT_RESOURCE_STATUSES = %w[not_checked checking enrolled not_enrolled denied exhausted pending_enrollment].freeze

  def change
    create_table :corvid_care_teams do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :corvid_care_teams, [ :tenant_identifier, :facility_identifier ]
    add_check_constraint :corvid_care_teams, "status IN (#{CARE_TEAM_STATUSES.map { |s| "'#{s}'" }.join(',')})", name: "corvid_care_teams_status_check"

    create_table :corvid_cases do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :care_team, foreign_key: { to_table: :corvid_care_teams }
      t.string :patient_identifier, null: false
      t.string :patient_name_cached
      t.date :patient_dob_cached
      t.string :status, null: false, default: "active"
      t.string :notes_token
      t.string :conditions_token
      t.string :program_type
      t.string :lifecycle_status, null: false, default: "intake"
      t.string :program_data_token
      t.datetime :intake_at
      t.datetime :closed_at
      t.string :closure_reason
      t.timestamps
    end
    add_index :corvid_cases, [ :tenant_identifier, :facility_identifier, :patient_identifier ]
    add_index :corvid_cases, [ :tenant_identifier, :status ]
    add_index :corvid_cases, [ :tenant_identifier, :program_type ]
    add_check_constraint :corvid_cases, "status IN (#{CASE_STATUSES.map { |s| "'#{s}'" }.join(',')})", name: "corvid_cases_status_check"
    add_check_constraint :corvid_cases, "lifecycle_status IN (#{CASE_LIFECYCLE.map { |s| "'#{s}'" }.join(',')})", name: "corvid_cases_lifecycle_check"

    create_table :corvid_prc_referrals do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :case, foreign_key: { to_table: :corvid_cases }, null: false
      t.string :referral_identifier, null: false
      t.string :status, null: false, default: "draft"
      t.string :current_activity
      t.string :authorization_number
      t.integer :medical_priority
      t.string :priority_system
      t.decimal :estimated_cost, precision: 12, scale: 2
      t.datetime :notification_date
      t.boolean :emergency_flag, default: false
      t.string :deferred_reason_token
      t.boolean :flagged_for_review, default: false
      t.string :late_notification_reason_token
      t.datetime :late_notification_documented_at
      t.string :late_notification_documented_by_identifier
      t.boolean :exception_approved
      t.string :exception_rationale_token
      t.datetime :exception_reviewed_at
      t.string :exception_reviewed_by_identifier
      t.datetime :medical_priority_cached_at
      t.datetime :authorization_number_cached_at
      t.timestamps
    end
    add_index :corvid_prc_referrals, [ :tenant_identifier, :facility_identifier, :referral_identifier ], unique: true, name: "idx_corvid_prc_referrals_tenant_referral"
    add_index :corvid_prc_referrals, [ :tenant_identifier, :status ]
    add_check_constraint :corvid_prc_referrals, "status IN (#{PRC_STATUSES.map { |s| "'#{s}'" }.join(',')})", name: "corvid_prc_referrals_status_check"

    create_table :corvid_tasks do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :taskable, polymorphic: true, null: false
      t.string :description
      t.string :notes_token
      t.string :assignee_identifier
      t.string :status, null: false, default: "pending"
      t.string :priority, null: false, default: "routine"
      t.datetime :due_at
      t.datetime :completed_at
      t.string :milestone_key
      t.integer :milestone_position
      t.boolean :required, default: false
      t.string :documentation_requirements_token
      t.timestamps
    end
    add_index :corvid_tasks, [ :tenant_identifier, :facility_identifier ]
    add_index :corvid_tasks, [ :tenant_identifier, :status ]
    add_index :corvid_tasks, [ :tenant_identifier, :assignee_identifier ]
    add_index :corvid_tasks, [ :taskable_type, :taskable_id, :milestone_key ], unique: true, where: "milestone_key IS NOT NULL", name: "idx_corvid_tasks_taskable_milestone"
    add_check_constraint :corvid_tasks, "status IN (#{TASK_STATUSES.map { |s| "'#{s}'" }.join(',')})", name: "corvid_tasks_status_check"
    add_check_constraint :corvid_tasks, "priority IN (#{TASK_PRIORITIES.map { |s| "'#{s}'" }.join(',')})", name: "corvid_tasks_priority_check"

    create_table :corvid_care_team_members do |t|
      t.references :care_team, null: false, foreign_key: { to_table: :corvid_care_teams }
      t.string :practitioner_identifier, null: false
      t.string :role
      t.boolean :lead, default: false
      t.date :start_date
      t.date :end_date
      t.timestamps
    end
    add_index :corvid_care_team_members, [ :care_team_id, :practitioner_identifier ], unique: true, name: "idx_corvid_ctm_team_practitioner"
    add_index :corvid_care_team_members, :practitioner_identifier

    create_table :corvid_committee_reviews do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :prc_referral, null: false, foreign_key: { to_table: :corvid_prc_referrals }
      t.string :reviewer_identifier
      t.date :committee_date
      t.string :decision, null: false, default: "pending"
      t.string :rationale_token
      t.decimal :approved_amount, precision: 12, scale: 2
      t.decimal :requested_amount, precision: 12, scale: 2
      t.string :attendees_token
      t.string :documents_reviewed_token
      t.string :conditions_token
      t.string :appeal_instructions_token
      t.date :appeal_deadline
      t.timestamps
    end
    add_index :corvid_committee_reviews, [ :tenant_identifier, :decision ]
    add_index :corvid_committee_reviews, :committee_date
    add_check_constraint :corvid_committee_reviews, "decision IN (#{COMMITTEE_DECISIONS.map { |s| "'#{s}'" }.join(',')})", name: "corvid_committee_reviews_decision_check"

    create_table :corvid_determinations do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.references :determinable, polymorphic: true, null: false
      t.string :determined_by_identifier
      t.string :decision_method, null: false
      t.string :outcome, null: false
      t.string :reasons_token
      t.string :determination_data_token
      t.datetime :determined_at
      t.timestamps
    end
    add_index :corvid_determinations, [ :determinable_type, :determinable_id ]
    add_index :corvid_determinations, [ :tenant_identifier, :outcome ]
    add_index :corvid_determinations, :determined_at
    add_check_constraint :corvid_determinations, "decision_method IN (#{DETERMINATION_DECISION_METHODS.map { |s| "'#{s}'" }.join(',')})", name: "corvid_determinations_method_check"
    add_check_constraint :corvid_determinations, "outcome IN (#{DETERMINATION_OUTCOMES.map { |s| "'#{s}'" }.join(',')})", name: "corvid_determinations_outcome_check"

    create_table :corvid_alternate_resource_checks do |t|
      t.references :prc_referral, null: false, foreign_key: { to_table: :corvid_prc_referrals }
      t.string :resource_type, null: false
      t.string :status, null: false, default: "not_checked"
      t.datetime :checked_at
      t.string :policy_token
      t.string :group_number
      t.string :payer_token
      t.date :coverage_start
      t.date :coverage_end
      t.string :response_data_token
      t.timestamps
    end
    add_index :corvid_alternate_resource_checks, [ :prc_referral_id, :resource_type ], unique: true, name: "idx_corvid_arc_referral_type"
    add_check_constraint :corvid_alternate_resource_checks, "resource_type IN (#{ALT_RESOURCE_TYPES.map { |s| "'#{s}'" }.join(',')})", name: "corvid_arc_resource_type_check"
    add_check_constraint :corvid_alternate_resource_checks, "status IN (#{ALT_RESOURCE_STATUSES.map { |s| "'#{s}'" }.join(',')})", name: "corvid_arc_status_check"

    create_table :corvid_fee_schedules do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :name, null: false
      t.string :program
      t.date :effective_date
      t.date :end_date
      t.string :tiers_token
      t.boolean :active, default: true
      t.timestamps
    end
    add_index :corvid_fee_schedules, [ :tenant_identifier, :facility_identifier ]
    add_index :corvid_fee_schedules, [ :tenant_identifier, :program ]
  end
end
