# frozen_string_literal: true

namespace :corvid do
  namespace :fmap do
    # Loads lib/corvid/data/fmap_rules.yml. Safe to re-run after a data
    # update (upsert by rule_key, never deletes). Until it runs,
    # classification refuses with no_rules_in_force. Prints a count only.
    desc "Load the shipped statutory FMAP rule set"
    task load_rules: :environment do
      puts Corvid::FmapRuleLoader.load_defaults!
    end
  end
end
