# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_06_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "corvid_alternate_resource_checks", force: :cascade do |t|
    t.datetime "checked_at"
    t.date "coverage_end"
    t.date "coverage_start"
    t.datetime "created_at", null: false
    t.string "group_number"
    t.string "payer_token"
    t.string "policy_token"
    t.bigint "prc_referral_id", null: false
    t.string "resource_type", null: false
    t.string "response_data_token"
    t.string "status", default: "not_checked", null: false
    t.datetime "updated_at", null: false
    t.index ["prc_referral_id", "resource_type"], name: "idx_corvid_arc_referral_type", unique: true
    t.index ["prc_referral_id"], name: "index_corvid_alternate_resource_checks_on_prc_referral_id"
    t.check_constraint "resource_type::text = ANY (ARRAY['medicare_a'::character varying, 'medicare_b'::character varying, 'medicare_d'::character varying, 'medicaid'::character varying, 'va_benefits'::character varying, 'private_insurance'::character varying, 'workers_comp'::character varying, 'auto_insurance'::character varying, 'liability_coverage'::character varying, 'state_program'::character varying, 'tribal_program'::character varying, 'charity_care'::character varying]::text[])", name: "corvid_arc_resource_type_check"
    t.check_constraint "status::text = ANY (ARRAY['not_checked'::character varying, 'checking'::character varying, 'enrolled'::character varying, 'not_enrolled'::character varying, 'denied'::character varying, 'exhausted'::character varying, 'pending_enrollment'::character varying]::text[])", name: "corvid_arc_status_check"
  end

  create_table "corvid_care_team_members", force: :cascade do |t|
    t.bigint "care_team_id", null: false
    t.datetime "created_at", null: false
    t.date "end_date"
    t.boolean "lead", default: false
    t.string "practitioner_identifier", null: false
    t.string "role"
    t.date "start_date"
    t.datetime "updated_at", null: false
    t.index ["care_team_id", "practitioner_identifier"], name: "idx_corvid_ctm_team_practitioner", unique: true
    t.index ["care_team_id"], name: "index_corvid_care_team_members_on_care_team_id"
    t.index ["practitioner_identifier"], name: "index_corvid_care_team_members_on_practitioner_identifier"
  end

  create_table "corvid_care_teams", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "facility_identifier"
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_identifier", "facility_identifier"], name: "idx_on_tenant_identifier_facility_identifier_6f25172ef7"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'inactive'::character varying]::text[])", name: "corvid_care_teams_status_check"
  end

  create_table "corvid_cases", force: :cascade do |t|
    t.bigint "care_team_id"
    t.datetime "closed_at"
    t.string "closure_reason"
    t.string "conditions_token"
    t.datetime "created_at", null: false
    t.string "facility_identifier"
    t.datetime "intake_at"
    t.string "lifecycle_status", default: "intake", null: false
    t.string "notes_token"
    t.date "patient_dob_cached"
    t.string "patient_identifier", null: false
    t.string "patient_name_cached"
    t.string "program_data_token"
    t.string "program_type"
    t.string "status", default: "active", null: false
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["care_team_id"], name: "index_corvid_cases_on_care_team_id"
    t.index ["tenant_identifier", "facility_identifier", "patient_identifier"], name: "idx_on_tenant_identifier_facility_identifier_patien_a3dd76b8ca"
    t.index ["tenant_identifier", "program_type"], name: "index_corvid_cases_on_tenant_identifier_and_program_type"
    t.index ["tenant_identifier", "status"], name: "index_corvid_cases_on_tenant_identifier_and_status"
    t.check_constraint "lifecycle_status::text = ANY (ARRAY['intake'::character varying, 'active_followup'::character varying, 'closure'::character varying, 'closed'::character varying]::text[])", name: "corvid_cases_lifecycle_check"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'inactive'::character varying, 'closed'::character varying]::text[])", name: "corvid_cases_status_check"
  end

  create_table "corvid_committee_reviews", force: :cascade do |t|
    t.date "appeal_deadline"
    t.string "appeal_instructions_token"
    t.decimal "approved_amount", precision: 12, scale: 2
    t.string "attendees_token"
    t.date "committee_date"
    t.string "conditions_token"
    t.datetime "created_at", null: false
    t.string "decision", default: "pending", null: false
    t.string "documents_reviewed_token"
    t.string "facility_identifier"
    t.bigint "prc_referral_id", null: false
    t.string "rationale_token"
    t.decimal "requested_amount", precision: 12, scale: 2
    t.string "reviewer_identifier"
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["committee_date"], name: "index_corvid_committee_reviews_on_committee_date"
    t.index ["prc_referral_id"], name: "index_corvid_committee_reviews_on_prc_referral_id"
    t.index ["tenant_identifier", "decision"], name: "idx_on_tenant_identifier_decision_51d5d49df2"
    t.check_constraint "decision::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying, 'denied'::character varying, 'deferred'::character varying, 'modified'::character varying]::text[])", name: "corvid_committee_reviews_decision_check"
  end

  create_table "corvid_determinations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "decision_method", null: false
    t.bigint "determinable_id", null: false
    t.string "determinable_type", null: false
    t.string "determination_data_token"
    t.datetime "determined_at"
    t.string "determined_by_identifier"
    t.string "facility_identifier"
    t.string "outcome", null: false
    t.string "reasons_token"
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["determinable_type", "determinable_id"], name: "idx_on_determinable_type_determinable_id_6da50e3199"
    t.index ["determinable_type", "determinable_id"], name: "index_corvid_determinations_on_determinable"
    t.index ["determined_at"], name: "index_corvid_determinations_on_determined_at"
    t.index ["tenant_identifier", "outcome"], name: "index_corvid_determinations_on_tenant_identifier_and_outcome"
    t.check_constraint "decision_method::text = ANY (ARRAY['automated'::character varying, 'staff_review'::character varying, 'committee_review'::character varying]::text[])", name: "corvid_determinations_method_check"
    t.check_constraint "outcome::text = ANY (ARRAY['approved'::character varying, 'denied'::character varying, 'deferred'::character varying, 'pending_review'::character varying]::text[])", name: "corvid_determinations_outcome_check"
  end

  create_table "corvid_fee_schedules", force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.date "effective_date"
    t.date "end_date"
    t.string "facility_identifier"
    t.string "name", null: false
    t.string "program"
    t.string "tenant_identifier", null: false
    t.string "tiers_token"
    t.datetime "updated_at", null: false
    t.index ["tenant_identifier", "facility_identifier"], name: "idx_on_tenant_identifier_facility_identifier_4bbe5beaee"
    t.index ["tenant_identifier", "program"], name: "index_corvid_fee_schedules_on_tenant_identifier_and_program"
  end

  create_table "corvid_prc_referrals", force: :cascade do |t|
    t.string "authorization_number"
    t.datetime "authorization_number_cached_at"
    t.bigint "case_id", null: false
    t.datetime "created_at", null: false
    t.string "current_activity"
    t.string "deferred_reason_token"
    t.boolean "emergency_flag", default: false
    t.decimal "estimated_cost", precision: 12, scale: 2
    t.boolean "exception_approved"
    t.string "exception_rationale_token"
    t.datetime "exception_reviewed_at"
    t.string "exception_reviewed_by_identifier"
    t.string "facility_identifier"
    t.boolean "flagged_for_review", default: false
    t.datetime "late_notification_documented_at"
    t.string "late_notification_documented_by_identifier"
    t.string "late_notification_reason_token"
    t.integer "medical_priority"
    t.datetime "medical_priority_cached_at"
    t.datetime "notification_date"
    t.string "priority_system"
    t.string "referral_identifier", null: false
    t.string "status", default: "draft", null: false
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["case_id"], name: "index_corvid_prc_referrals_on_case_id"
    t.index ["tenant_identifier", "facility_identifier", "referral_identifier"], name: "idx_corvid_prc_referrals_tenant_referral", unique: true
    t.index ["tenant_identifier", "status"], name: "index_corvid_prc_referrals_on_tenant_identifier_and_status"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'submitted'::character varying, 'eligibility_review'::character varying, 'alternate_resource_review'::character varying, 'priority_assignment'::character varying, 'committee_review'::character varying, 'exception_review'::character varying, 'authorized'::character varying, 'denied'::character varying, 'deferred'::character varying, 'cancelled'::character varying]::text[])", name: "corvid_prc_referrals_status_check"
  end

  create_table "corvid_tasks", force: :cascade do |t|
    t.string "assignee_identifier"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "description"
    t.string "documentation_requirements_token"
    t.datetime "due_at"
    t.string "facility_identifier"
    t.string "milestone_key"
    t.integer "milestone_position"
    t.string "notes_token"
    t.string "priority", default: "routine", null: false
    t.boolean "required", default: false
    t.string "status", default: "pending", null: false
    t.bigint "taskable_id", null: false
    t.string "taskable_type", null: false
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["taskable_type", "taskable_id", "milestone_key"], name: "idx_corvid_tasks_taskable_milestone", unique: true, where: "(milestone_key IS NOT NULL)"
    t.index ["taskable_type", "taskable_id"], name: "index_corvid_tasks_on_taskable"
    t.index ["tenant_identifier", "assignee_identifier"], name: "idx_on_tenant_identifier_assignee_identifier_35adb7cf72"
    t.index ["tenant_identifier", "facility_identifier"], name: "idx_on_tenant_identifier_facility_identifier_aa1e96cb7e"
    t.index ["tenant_identifier", "status"], name: "index_corvid_tasks_on_tenant_identifier_and_status"
    t.check_constraint "priority::text = ANY (ARRAY['asap'::character varying, 'urgent'::character varying, 'routine'::character varying]::text[])", name: "corvid_tasks_priority_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'in_progress'::character varying, 'completed'::character varying, 'cancelled'::character varying]::text[])", name: "corvid_tasks_status_check"
  end

  add_foreign_key "corvid_alternate_resource_checks", "corvid_prc_referrals", column: "prc_referral_id"
  add_foreign_key "corvid_care_team_members", "corvid_care_teams", column: "care_team_id"
  add_foreign_key "corvid_cases", "corvid_care_teams", column: "care_team_id"
  add_foreign_key "corvid_committee_reviews", "corvid_prc_referrals", column: "prc_referral_id"
  add_foreign_key "corvid_prc_referrals", "corvid_cases", column: "case_id"
end
