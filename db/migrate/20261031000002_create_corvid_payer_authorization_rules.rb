# frozen_string_literal: true

# Tenant-maintained payer authorization rules. A missing row must never
# be stored as "not required" — lookup treats absence as unknown — so the
# CHECKs only allow the three real requirement values and a single,
# well-formed code target. NULL place or plan means any; blank text is
# not that wildcard.
class CreateCorvidPayerAuthorizationRules < ActiveRecord::Migration[8.1]
  REQUIREMENTS = %w[required not_required documentation_only].freeze
  CODE_SHAPE = "^[A-Z0-9]{5}$"
  # Same mapping as PayerAuthorizationRule::CODE_PATTERN_FROM/TO.
  # Kept here so the migration does not call the model.
  PATTERN_FROM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  PATTERN_TO = "9999999999AAAAAAAAAAAAAAAAAAAAAAAAAA"

  def change
    create_table :corvid_payer_authorization_rules do |t|
      t.string :tenant_identifier, null: false
      t.string :payer_identifier, null: false
      t.string :service_code
      t.string :code_from
      t.string :code_to
      t.string :place_of_service
      t.string :plan_identifier
      t.string :requirement, null: false
      t.date :effective_on, null: false
      t.date :expires_on

      t.timestamps
    end

    add_index :corvid_payer_authorization_rules,
              [ :tenant_identifier, :payer_identifier ],
              name: "idx_corvid_payer_auth_rules_tenant_payer"

    add_value_checks
    add_code_checks
    add_pattern_check
  end

  private

  def add_value_checks
    quoted = REQUIREMENTS.map { |value| connection.quote(value) }.join(", ")
    add_check_constraint :corvid_payer_authorization_rules,
                         "requirement IN (#{quoted})",
                         name: "corvid_payer_auth_rules_requirement_check"
    add_check_constraint :corvid_payer_authorization_rules,
                         "expires_on IS NULL OR expires_on >= effective_on",
                         name: "corvid_payer_auth_rules_expires_on_check"
    add_check_constraint :corvid_payer_authorization_rules,
                         "payer_identifier !~ '^[[:space:]]*$'",
                         name: "corvid_payer_auth_rules_payer_check"
    add_check_constraint :corvid_payer_authorization_rules,
                         "place_of_service IS NULL OR place_of_service !~ '^[[:space:]]*$'",
                         name: "corvid_payer_auth_rules_pos_check"
    add_check_constraint :corvid_payer_authorization_rules,
                         "plan_identifier IS NULL OR plan_identifier !~ '^[[:space:]]*$'",
                         name: "corvid_payer_auth_rules_plan_check"
  end

  def add_code_checks
    add_check_constraint :corvid_payer_authorization_rules,
                         "(service_code IS NOT NULL AND code_from IS NULL AND code_to IS NULL) OR " \
                         "(service_code IS NULL AND code_from IS NOT NULL AND code_to IS NOT NULL)",
                         name: "corvid_payer_auth_rules_code_form_check"
    add_check_constraint :corvid_payer_authorization_rules,
                         "service_code IS NULL OR service_code ~ '#{CODE_SHAPE}'",
                         name: "corvid_payer_auth_rules_service_code_check"
    add_check_constraint :corvid_payer_authorization_rules,
                         "code_from IS NULL OR code_from ~ '#{CODE_SHAPE}'",
                         name: "corvid_payer_auth_rules_code_from_check"
    add_check_constraint :corvid_payer_authorization_rules,
                         "code_to IS NULL OR code_to ~ '#{CODE_SHAPE}'",
                         name: "corvid_payer_auth_rules_code_to_check"
    # Same length keeps string order aligned with code order. A reversed
    # range would match nothing and look like a gap.
    add_check_constraint :corvid_payer_authorization_rules,
                         "(code_from IS NULL AND code_to IS NULL) OR " \
                         "(char_length(code_from) = char_length(code_to) AND code_from <= code_to)",
                         name: "corvid_payer_auth_rules_code_range_check"
  end

  # When both ends are present they share one digit/letter pattern.
  # A NULL end is an exact service code, or a partial row the form
  # check already rejects. "10000" and "6999F" are not one pattern.
  def add_pattern_check
    from = connection.quote(PATTERN_FROM)
    to = connection.quote(PATTERN_TO)
    same_pattern = "translate(code_from, #{from}, #{to}) = translate(code_to, #{from}, #{to})"
    add_check_constraint :corvid_payer_authorization_rules,
                         "code_from IS NULL OR code_to IS NULL OR (#{same_pattern})",
                         name: "corvid_payer_auth_rules_code_pattern_check"
  end
end
