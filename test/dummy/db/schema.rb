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

ActiveRecord::Schema[8.1].define(version: 2026_04_15_000005) do
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

  create_table "corvid_billing_transactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "direction", default: "outbound", null: false
    t.string "error_message"
    t.string "facility_identifier"
    t.string "patient_identifier"
    t.string "reference_identifier"
    t.string "request_token"
    t.string "response_token"
    t.string "status", default: "pending", null: false
    t.string "tenant_identifier", null: false
    t.string "transaction_type", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_identifier", "reference_identifier"], name: "idx_on_tenant_identifier_reference_identifier_6214d6a05c"
    t.index ["tenant_identifier", "transaction_type"], name: "idx_on_tenant_identifier_transaction_type_c3e90efcf5"
    t.check_constraint "direction::text = ANY (ARRAY['inbound'::character varying, 'outbound'::character varying]::text[])", name: "corvid_billing_tx_direction_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'completed'::character varying, 'failed'::character varying]::text[])", name: "corvid_billing_tx_status_check"
    t.check_constraint "transaction_type::text = ANY (ARRAY['eligibility'::character varying, 'claim'::character varying, 'claim_status'::character varying, 'remittance'::character varying, 'payment'::character varying]::text[])", name: "corvid_billing_tx_type_check"
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

  create_table "corvid_claim_submissions", force: :cascade do |t|
    t.decimal "adjustment_amount", precision: 12, scale: 2
    t.decimal "billed_amount", precision: 12, scale: 2
    t.string "claim_identifier"
    t.string "claim_type", default: "professional", null: false
    t.decimal "county_share", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.string "denial_reason_token"
    t.string "diagnosis_codes_token"
    t.string "facility_identifier"
    t.datetime "last_checked_at"
    t.decimal "paid_amount", precision: 12, scale: 2
    t.date "paid_date"
    t.string "patient_identifier", null: false
    t.decimal "patient_responsibility", precision: 12, scale: 2
    t.string "payer_identifier"
    t.string "payer_name_token"
    t.string "procedure_codes_token"
    t.string "provider_identifier"
    t.string "provider_type"
    t.string "referral_identifier"
    t.date "service_date"
    t.decimal "state_share", precision: 12, scale: 2
    t.string "status", default: "draft", null: false
    t.datetime "submitted_at"
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["claim_identifier"], name: "index_corvid_claim_submissions_on_claim_identifier", unique: true
    t.index ["tenant_identifier", "patient_identifier"], name: "idx_on_tenant_identifier_patient_identifier_0a950bd516"
    t.index ["tenant_identifier", "status"], name: "index_corvid_claim_submissions_on_tenant_identifier_and_status"
    t.check_constraint "claim_type::text = ANY (ARRAY['professional'::character varying, 'institutional'::character varying, 'dental'::character varying]::text[])", name: "corvid_claim_submissions_type_check"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'submitted'::character varying, 'accepted'::character varying, 'rejected'::character varying, 'paid'::character varying, 'denied'::character varying, 'appealed'::character varying]::text[])", name: "corvid_claim_submissions_status_check"
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

  create_table "corvid_eligibility_checklists", force: :cascade do |t|
    t.boolean "application_complete", default: false, null: false
    t.datetime "application_completed_at"
    t.string "application_completed_by"
    t.string "clinical_necessity_documentation_source"
    t.boolean "clinical_necessity_documented", default: false, null: false
    t.datetime "clinical_necessity_documented_at"
    t.datetime "created_at", null: false
    t.string "enrollment_verification_source"
    t.boolean "enrollment_verified", default: false, null: false
    t.datetime "enrollment_verified_at"
    t.string "facility_identifier"
    t.string "identity_verification_source"
    t.boolean "identity_verified", default: false, null: false
    t.datetime "identity_verified_at"
    t.string "insurance_verification_source"
    t.boolean "insurance_verified", default: false, null: false
    t.datetime "insurance_verified_at"
    t.boolean "management_approved", default: false, null: false
    t.datetime "management_approved_at"
    t.string "management_approved_by"
    t.bigint "prc_referral_id", null: false
    t.string "residency_verification_source"
    t.boolean "residency_verified", default: false, null: false
    t.datetime "residency_verified_at"
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["prc_referral_id"], name: "idx_corvid_elig_checklists_referral_unique", unique: true
    t.index ["tenant_identifier", "facility_identifier"], name: "idx_corvid_elig_checklists_tenant_facility"
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

  create_table "corvid_payments", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.string "claim_submission_identifier"
    t.datetime "created_at", null: false
    t.string "description"
    t.string "facility_identifier"
    t.string "patient_identifier", null: false
    t.string "payment_identifier"
    t.string "status", default: "pending", null: false
    t.string "tenant_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["payment_identifier"], name: "index_corvid_payments_on_payment_identifier", unique: true
    t.index ["tenant_identifier", "patient_identifier"], name: "idx_on_tenant_identifier_patient_identifier_238e33c764"
    t.index ["tenant_identifier", "status"], name: "index_corvid_payments_on_tenant_identifier_and_status"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'processing'::character varying, 'succeeded'::character varying, 'failed'::character varying, 'refunded'::character varying]::text[])", name: "corvid_payments_status_check"
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
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'submitted'::character varying, 'eligibility_review'::character varying, 'management_approval'::character varying, 'alternate_resource_review'::character varying, 'priority_assignment'::character varying, 'committee_review'::character varying, 'exception_review'::character varying, 'authorized'::character varying, 'denied'::character varying, 'deferred'::character varying, 'cancelled'::character varying]::text[])", name: "corvid_prc_referrals_status_check"
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
    t.check_constraint "priority::text = ANY (ARRAY['routine'::character varying, 'urgent'::character varying, 'asap'::character varying, 'stat'::character varying]::text[])", name: "corvid_tasks_priority_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'in_progress'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'on_hold'::character varying]::text[])", name: "corvid_tasks_status_check"
  end

  add_foreign_key "corvid_alternate_resource_checks", "corvid_prc_referrals", column: "prc_referral_id"
  add_foreign_key "corvid_care_team_members", "corvid_care_teams", column: "care_team_id"
  add_foreign_key "corvid_cases", "corvid_care_teams", column: "care_team_id"
  add_foreign_key "corvid_committee_reviews", "corvid_prc_referrals", column: "prc_referral_id"
  add_foreign_key "corvid_eligibility_checklists", "corvid_prc_referrals", column: "prc_referral_id"
  add_foreign_key "corvid_prc_referrals", "corvid_cases", column: "case_id"
end
