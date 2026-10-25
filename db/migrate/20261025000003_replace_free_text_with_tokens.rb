# frozen_string_literal: true

# ADR 0001: claim_reference becomes claim_identifier.
# ADR 0002: string enums and token columns are CHECK-constrained.
# ADR 0003 §4: no free text at rest. up counts non-token values and
# aborts with those counts only — the message never includes a stored value.
# current_activity is not parsed. Only the engine literal
# "Submitted via FHIR PAS" is mapped; every other value is dropped.
class ReplaceFreeTextWithTokens < ActiveRecord::Migration[8.1]
  # Postgres form of Corvid::OpaqueToken::FORMAT (ADR 0003 §4).
  TOKEN_PATTERN = "^[a-z]{2,4}_[0-9A-HJKMNP-TV-Z]{26}$"
  # True when an evidence_refs element ref is not a token string.
  BAD_EVIDENCE_REF = %q{$[*] ? (!(@.ref.type() == "string" && @.ref like_regex "^[a-z]{2,4}_[0-9A-HJKMNP-TV-Z]{26}$"))}

  CLAIM_CHECK = "corvid_fmap_determinations_claim_identifier_check"
  EVIDENCE_CHECK = "corvid_fmap_determinations_evidence_refs_check"
  ACTIVITY_CODE_CHECK = "corvid_prc_referrals_current_activity_code_check"
  REVIEWER_CHECK = "corvid_prc_referrals_reviewer_identifier_check"
  ASSIGNED_REVIEWER_CHECK = "corvid_prc_referrals_assigned_reviewer_check"

  ACTIVITY_CODES = %w[submitted_via_fhir_pas assigned_to_reviewer].freeze
  SUBMITTED_CODE = "submitted_via_fhir_pas"
  ASSIGNED_CODE = "assigned_to_reviewer"
  SUBMITTED_TEXT = "Submitted via FHIR PAS"
  ASSIGNED_TEXT = "Assigned to reviewer"

  def up
    transaction do
      refuse_non_token_rows!
      rename_claim_reference
      constrain_evidence_refs
      replace_current_activity
    end
  end

  def down
    transaction do
      restore_current_activity
      restore_claim_reference
    end
  end

  private

  def refuse_non_token_rows!
    claim_count = non_token_claim_count
    evidence_count = non_token_evidence_count
    return if claim_count.zero? && evidence_count.zero?

    raise "refusing to replace free text with tokens: " \
          "#{claim_count} non-token claim_reference row(s), " \
          "#{evidence_count} row(s) with a non-token evidence ref"
  end

  def non_token_claim_count
    select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM corvid_fmap_determinations
      WHERE claim_reference IS NOT NULL
        AND claim_reference !~ #{quote(TOKEN_PATTERN)}
    SQL
  end

  def non_token_evidence_count
    select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM corvid_fmap_determinations
      WHERE jsonb_path_exists(evidence_refs, #{quote(BAD_EVIDENCE_REF)})
    SQL
  end

  def rename_claim_reference
    rename_column :corvid_fmap_determinations, :claim_reference, :claim_identifier
    add_check_constraint :corvid_fmap_determinations, claim_identifier_check_sql, name: CLAIM_CHECK
  end

  def constrain_evidence_refs
    add_check_constraint :corvid_fmap_determinations, evidence_refs_check_sql, name: EVIDENCE_CHECK
  end

  def replace_current_activity
    add_column :corvid_prc_referrals, :current_activity_code, :string
    add_column :corvid_prc_referrals, :reviewer_identifier, :string
    add_activity_checks
    map_submitted_via_fhir_activity
    remove_column :corvid_prc_referrals, :current_activity
  end

  def add_activity_checks
    add_check_constraint :corvid_prc_referrals, activity_code_check_sql, name: ACTIVITY_CODE_CHECK
    add_check_constraint :corvid_prc_referrals, reviewer_identifier_check_sql, name: REVIEWER_CHECK
    add_check_constraint :corvid_prc_referrals, assigned_reviewer_check_sql, name: ASSIGNED_REVIEWER_CHECK
  end

  def map_submitted_via_fhir_activity
    execute <<~SQL
      UPDATE corvid_prc_referrals
      SET current_activity_code = #{quote(SUBMITTED_CODE)}
      WHERE current_activity = #{quote(SUBMITTED_TEXT)}
    SQL
  end

  def restore_current_activity
    return unless column_exists?(:corvid_prc_referrals, :current_activity_code)

    add_column :corvid_prc_referrals, :current_activity, :string unless column_exists?(:corvid_prc_referrals, :current_activity)
    backfill_current_activity
    remove_activity_checks
    remove_column :corvid_prc_referrals, :reviewer_identifier if column_exists?(:corvid_prc_referrals, :reviewer_identifier)
    remove_column :corvid_prc_referrals, :current_activity_code
  end

  def backfill_current_activity
    execute <<~SQL
      UPDATE corvid_prc_referrals
      SET current_activity = CASE current_activity_code
        WHEN #{quote(SUBMITTED_CODE)} THEN #{quote(SUBMITTED_TEXT)}
        WHEN #{quote(ASSIGNED_CODE)} THEN #{quote(ASSIGNED_TEXT)}
        ELSE NULL
      END
    SQL
  end

  def remove_activity_checks
    remove_check_constraint :corvid_prc_referrals, name: ASSIGNED_REVIEWER_CHECK, if_exists: true
    remove_check_constraint :corvid_prc_referrals, name: REVIEWER_CHECK, if_exists: true
    remove_check_constraint :corvid_prc_referrals, name: ACTIVITY_CODE_CHECK, if_exists: true
  end

  def restore_claim_reference
    if column_exists?(:corvid_fmap_determinations, :claim_identifier)
      remove_check_constraint :corvid_fmap_determinations, name: CLAIM_CHECK, if_exists: true
      rename_column :corvid_fmap_determinations, :claim_identifier, :claim_reference
    end
    remove_check_constraint :corvid_fmap_determinations, name: EVIDENCE_CHECK, if_exists: true
  end

  def claim_identifier_check_sql
    "claim_identifier IS NULL OR claim_identifier ~ #{quote(TOKEN_PATTERN)}"
  end

  def evidence_refs_check_sql
    "NOT jsonb_path_exists(evidence_refs, #{quote(BAD_EVIDENCE_REF)})"
  end

  def activity_code_check_sql
    codes = ACTIVITY_CODES.map { |code| quote(code) }.join(", ")
    "current_activity_code IS NULL OR current_activity_code IN (#{codes})"
  end

  def reviewer_identifier_check_sql
    "reviewer_identifier IS NULL OR reviewer_identifier ~ #{quote(TOKEN_PATTERN)}"
  end

  def assigned_reviewer_check_sql
    "current_activity_code IS DISTINCT FROM #{quote(ASSIGNED_CODE)} OR reviewer_identifier IS NOT NULL"
  end
end
