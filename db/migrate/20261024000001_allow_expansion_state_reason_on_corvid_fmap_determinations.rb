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
    # The prior list cannot store expansion_state_not_configured.
    # Remove those rows before rolling back; the reason is not rewritten.
    replace_reason_check(PRIOR_REASONS)
  end

  private

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
