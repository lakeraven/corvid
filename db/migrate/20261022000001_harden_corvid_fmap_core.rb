# frozen_string_literal: true

class HardenCorvidFmapCore < ActiveRecord::Migration[8.1]
  RULE_CATEGORIES = %w[
    fmap_100_ihs_638 fmap_100_cca fmap_100_uio fmap_90_expansion fmap_regular non_medicaid
  ].freeze
  DETERMINATION_CATEGORIES = (RULE_CATEGORIES + %w[undetermined]).freeze
  AUTHORITY_TYPES = %w[ihs_direct contract_638 compact_638 uio fqhc other].freeze
  RECEIVED_THROUGH_BASES = %w[facility_authority cca].freeze
  COVERAGE_GROUPS = %w[expansion_adult waiver_adult other].freeze
  REASONS = %w[no_rules_in_force no_matching_rule unevidenced_100_percent].freeze

  def up
    # The determination records the authority and authority type it was
    # decided on, so an audit can reconstruct a received-through basis.
    add_reference :corvid_fmap_determinations, :facility_authority,
                  foreign_key: { to_table: :corvid_facility_authorities },
                  index: { name: "idx_corvid_fmap_determinations_authority" }
    add_column :corvid_fmap_determinations, :authority_type, :string
    add_foreign_key :corvid_fmap_determinations, :corvid_fmap_determinations, column: :superseded_by_id
    add_index :corvid_fmap_determinations, :superseded_by_id, unique: true,
              where: "superseded_by_id IS NOT NULL",
              name: "idx_corvid_fmap_determinations_superseded_by"

    # Coverage groups use the StateMedicaidRules vocabulary.
    execute "UPDATE corvid_fmap_rules SET coverage_group = 'expansion_adult' WHERE coverage_group = 'expansion'"

    add_check_constraint :corvid_fmap_rules, "category IN (#{quoted(RULE_CATEGORIES)})",
                         name: "corvid_fmap_rules_category_check"
    add_check_constraint :corvid_fmap_rules, "coverage_group IS NULL OR coverage_group IN (#{quoted(COVERAGE_GROUPS)})",
                         name: "corvid_fmap_rules_coverage_group_check"
    add_check_constraint :corvid_facility_authorities, "authority_type IN (#{quoted(AUTHORITY_TYPES)})",
                         name: "corvid_facility_authorities_type_check"
    add_check_constraint :corvid_fmap_determinations, "category IN (#{quoted(DETERMINATION_CATEGORIES)})",
                         name: "corvid_fmap_determinations_category_check"
    add_check_constraint :corvid_fmap_determinations,
                         "best_available_category IS NULL OR best_available_category IN (#{quoted(RULE_CATEGORIES)})",
                         name: "corvid_fmap_determinations_best_category_check"
    add_check_constraint :corvid_fmap_determinations,
                         "received_through_basis IS NULL OR received_through_basis IN (#{quoted(RECEIVED_THROUGH_BASES)})",
                         name: "corvid_fmap_determinations_basis_check"
    add_check_constraint :corvid_fmap_determinations,
                         "authority_type IS NULL OR authority_type IN (#{quoted(AUTHORITY_TYPES)})",
                         name: "corvid_fmap_determinations_authority_type_check"
    # A determination may also record "unknown", which matches no group rule.
    add_check_constraint :corvid_fmap_determinations,
                         "coverage_group IS NULL OR coverage_group IN (#{quoted(COVERAGE_GROUPS + %w[unknown])})",
                         name: "corvid_fmap_determinations_coverage_group_check"
    add_check_constraint :corvid_fmap_determinations,
                         "determination_reason IS NULL OR determination_reason IN (#{quoted(REASONS)})",
                         name: "corvid_fmap_determinations_reason_check"
    # An undetermined row applies no rule and no percent, and says why.
    add_check_constraint :corvid_fmap_determinations,
                         "category <> 'undetermined' OR (rule_key IS NULL AND fmap_percent IS NULL " \
                         "AND determination_reason IS NOT NULL)",
                         name: "corvid_fmap_determinations_undetermined_check"
  end

  def down
    remove_check_constraint :corvid_fmap_determinations, name: "corvid_fmap_determinations_undetermined_check",
                                                         if_exists: true
    remove_check_constraint :corvid_fmap_determinations, name: "corvid_fmap_determinations_reason_check", if_exists: true
    remove_check_constraint :corvid_fmap_determinations, name: "corvid_fmap_determinations_coverage_group_check",
                                                         if_exists: true
    remove_check_constraint :corvid_fmap_determinations, name: "corvid_fmap_determinations_authority_type_check"
    remove_check_constraint :corvid_fmap_determinations, name: "corvid_fmap_determinations_basis_check"
    remove_check_constraint :corvid_fmap_determinations, name: "corvid_fmap_determinations_best_category_check"
    remove_check_constraint :corvid_fmap_determinations, name: "corvid_fmap_determinations_category_check"
    remove_check_constraint :corvid_facility_authorities, name: "corvid_facility_authorities_type_check"
    remove_check_constraint :corvid_fmap_rules, name: "corvid_fmap_rules_coverage_group_check"
    remove_check_constraint :corvid_fmap_rules, name: "corvid_fmap_rules_category_check"
    remove_index :corvid_fmap_determinations, name: "idx_corvid_fmap_determinations_superseded_by"
    remove_foreign_key :corvid_fmap_determinations, column: :superseded_by_id
    remove_column :corvid_fmap_determinations, :authority_type
    remove_reference :corvid_fmap_determinations, :facility_authority,
                     foreign_key: { to_table: :corvid_facility_authorities },
                     index: { name: "idx_corvid_fmap_determinations_authority" }
  end

  private

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(",")
  end
end
