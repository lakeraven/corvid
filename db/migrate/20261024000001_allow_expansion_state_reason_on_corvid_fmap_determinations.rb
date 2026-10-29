# frozen_string_literal: true

# The 90% expansion tier is refused when the jurisdiction is not a
# configured expansion state. That refusal is persisted as
# expansion_state_not_configured, so the reason CHECK has to accept it.
class AllowExpansionStateReasonOnCorvidFmapDeterminations < ActiveRecord::Migration[8.1]
  REASONS = %w[
    no_rules_in_force no_matching_rule unevidenced_100_percent expansion_state_not_configured
  ].freeze
  PRIOR_REASONS = %w[no_rules_in_force no_matching_rule unevidenced_100_percent].freeze

  def up
    replace_reason_check(REASONS)
  end

  def down
    # The prior list cannot store expansion_state_not_configured, or any
    # other reason added after it. Check before touching the constraint:
    # replacing it raises a raw check violation while such rows exist.
    # Do not delete or rewrite them; refuse the rollback instead.
    held = determination_reasons_outside(PRIOR_REASONS)
    if held.any?
      raise ActiveRecord::IrreversibleMigration,
        "corvid_fmap_determinations rows hold determination_reason #{held.join(', ')}; " \
        "the prior check cannot store that reason, so this migration is irreversible. " \
        "Rows were not deleted or rewritten."
    end

    replace_reason_check(PRIOR_REASONS)
  end

  private

  def determination_reasons_outside(allowed)
    table = connection.quote_table_name("corvid_fmap_determinations")
    listed = allowed.map { |reason| connection.quote(reason) }.join(", ")
    connection.select_values(<<~SQL.squish)
      SELECT DISTINCT determination_reason
      FROM #{table}
      WHERE determination_reason IS NOT NULL
        AND determination_reason NOT IN (#{listed})
      ORDER BY determination_reason
    SQL
  end

  def replace_reason_check(reasons)
    remove_check_constraint :corvid_fmap_determinations, name: "corvid_fmap_determinations_reason_check"
    add_check_constraint :corvid_fmap_determinations,
                         "determination_reason IS NULL OR determination_reason IN (#{quoted(reasons)})",
                         name: "corvid_fmap_determinations_reason_check"
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(",")
  end
end
