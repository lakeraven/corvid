# frozen_string_literal: true

module Corvid
  # Loads the shipped statutory FMAP rule set (lib/corvid/data/fmap_rules.yml)
  # into corvid_fmap_rules. Upserts by rule_key so re-running after a data
  # update is safe; never deletes — a rule leaving the statute books must
  # be end-dated in data, not vanished, or historical classification by
  # date of service breaks.
  class FmapRuleLoader
    DATA_PATH = Corvid::Engine.root.join("lib", "corvid", "data", "fmap_rules.yml")

    def self.load_defaults!(path: DATA_PATH)
      rows = YAML.safe_load_file(path, permitted_classes: [ Date ])
      # All or nothing: a partial rule set would classify against an
      # incomplete statute set.
      FmapRule.transaction(requires_new: true) do
        rows.each do |row|
          rule = FmapRule.find_or_initialize_by(rule_key: row.fetch("rule_key"))
          rule.update!(row)
        end
      end
      FmapRule.count
    end
  end
end
