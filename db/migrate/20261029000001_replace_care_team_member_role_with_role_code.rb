# frozen_string_literal: true

# ADR 0002: role_code is a string enum with a CHECK.
# ADR 0003: free text is not stored. up maps only the unambiguous
# legacy role strings below, including the display labels down writes.
# NULL, blank, and anything else abort with a row count only — the
# message never includes a stored value.
class ReplaceCareTeamMemberRoleWithRoleCode < ActiveRecord::Migration[8.1]
  ROLE_CODE_CHECK = "corvid_care_team_members_role_code_check"

  ROLE_CODES = %w[primary_care_provider care_manager consultant other].freeze

  LEGACY_ROLE_CODES = {
    "PCP" => "primary_care_provider",
    "Primary Care Provider" => "primary_care_provider",
    "primary care physician" => "primary_care_provider",
    "Primary care provider" => "primary_care_provider",
    "Care Manager" => "care_manager",
    "Case Manager" => "care_manager",
    "Care manager" => "care_manager",
    "Consultant" => "consultant",
    "Other" => "other"
  }.freeze

  ROLE_LABELS = {
    "primary_care_provider" => "Primary care provider",
    "care_manager" => "Care manager",
    "consultant" => "Consultant",
    "other" => "Other"
  }.freeze

  def up
    transaction do
      refuse_unmappable_roles!
      replace_role_with_role_code
    end
  end

  def down
    transaction do
      restore_role
    end
  end

  private

  def refuse_unmappable_roles!
    count = unmappable_role_count
    return if count.zero?

    raise "refusing to replace care team member role with role_code: " \
          "#{count} row(s) with unmappable role"
  end

  def unmappable_role_count
    select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM corvid_care_team_members
      WHERE role IS NULL
         OR role NOT IN (#{quoted_legacy_roles})
    SQL
  end

  def replace_role_with_role_code
    add_column :corvid_care_team_members, :role_code, :string
    map_role_codes
    change_column_null :corvid_care_team_members, :role_code, false
    add_check_constraint :corvid_care_team_members, role_code_check_sql, name: ROLE_CODE_CHECK
    remove_column :corvid_care_team_members, :role
  end

  def map_role_codes
    execute <<~SQL
      UPDATE corvid_care_team_members
      SET role_code = CASE role
        #{legacy_role_whens}
        ELSE NULL
      END
    SQL
  end

  def restore_role
    return unless column_exists?(:corvid_care_team_members, :role_code)

    add_column :corvid_care_team_members, :role, :string unless column_exists?(:corvid_care_team_members, :role)
    backfill_role
    remove_check_constraint :corvid_care_team_members, name: ROLE_CODE_CHECK, if_exists: true
    remove_column :corvid_care_team_members, :role_code
  end

  def backfill_role
    execute <<~SQL
      UPDATE corvid_care_team_members
      SET role = CASE role_code
        #{label_whens}
        ELSE NULL
      END
    SQL
  end

  # An IN list is stored as ANY (ARRAY[...]::text[]). Loading the schema
  # dump and reading it back adds a text cast on each element instead.
  # Spell that cast so a down/up replay matches the schema-loaded CHECK.
  def role_code_check_sql
    codes = ROLE_CODES.map { |code| "#{quote(code)}::character varying" }.join(", ")
    "role_code::text = ANY (ARRAY[#{codes}]::text[])"
  end

  def quoted_legacy_roles
    LEGACY_ROLE_CODES.keys.map { |role| quote(role) }.join(", ")
  end

  def legacy_role_whens
    LEGACY_ROLE_CODES.map { |text, code| "WHEN #{quote(text)} THEN #{quote(code)}" }.join("\n")
  end

  def label_whens
    ROLE_LABELS.map { |code, label| "WHEN #{quote(code)} THEN #{quote(label)}" }.join("\n")
  end
end
