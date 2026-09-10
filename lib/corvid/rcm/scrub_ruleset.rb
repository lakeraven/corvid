# frozen_string_literal: true

require "date"
require "yaml"

module Corvid
  module Rcm
    SCRUB_SEVERITIES = %i[block warn].freeze

    # One scrub rule, loaded from data.
    #
    # `message` says what is wrong with THIS claim (interpolated with values the
    # check supplies); `remedy` says what to do. Both are data so a billing lead
    # can improve the wording of an unhelpful message without a code change.
    ScrubRule = Data.define(
      :id, :category, :severity, :check, :params, :message, :remedy,
      :effective_start, :effective_end
    ) do
      def initialize(id:, check:, message:, severity: :block, category: :uncategorized,
                     params: {}, remedy: nil, effective_start: nil, effective_end: nil)
        unless SCRUB_SEVERITIES.include?(severity)
          raise ArgumentError, "rule #{id}: unknown severity #{severity.inspect}"
        end

        super
      end

      # Rules are evaluated as of a date — normally the date of service, so a
      # claim worked months later is still judged by the rules that were in
      # force when the service happened.
      def effective_on?(date)
        return false if effective_start && date < effective_start
        return false if effective_end && date > effective_end

        true
      end

      def blocking?
        severity == :block
      end
    end

    # A versioned collection of scrub rules loaded from YAML.
    class ScrubRuleset
      DEFAULT_PATH = File.expand_path("data/scrub_rules.yml", __dir__)

      class InvalidRuleset < StandardError; end

      class << self
        def default
          @default ||= load(DEFAULT_PATH)
        end

        def load(path)
          from_hash(YAML.safe_load_file(path, permitted_classes: [ Date ]))
        end

        def from_hash(table)
          rules = Array(table["rules"]).map { |row| build_rule(row) }
          raise InvalidRuleset, "ruleset contains no rules" if rules.empty?

          duplicate = rules.map(&:id).tally.find { |_id, count| count > 1 }
          raise InvalidRuleset, "duplicate rule id #{duplicate.first}" if duplicate

          new(version: table.fetch("ruleset_version"), rules: rules)
        end

        def reset_default!
          @default = nil
        end

        private

        def build_rule(row)
          ScrubRule.new(
            id: row.fetch("id").to_sym,
            category: row.fetch("category", "uncategorized").to_sym,
            severity: row.fetch("severity", "block").to_sym,
            check: row.fetch("check").to_sym,
            params: row.fetch("params", {}) || {},
            message: row.fetch("message"),
            remedy: row["remedy"],
            effective_start: to_date(row["effective_start"]),
            effective_end: to_date(row["effective_end"])
          )
        end

        def to_date(value)
          return nil if value.nil? || value.to_s.strip.empty?
          return value if value.is_a?(Date)

          Date.parse(value.to_s)
        end
      end

      attr_reader :version, :rules

      def initialize(version:, rules:)
        @version = version
        @rules = rules.freeze
      end

      def rule(id)
        @rules.find { |rule| rule.id == id.to_sym }
      end

      def categories
        @rules.map(&:category).uniq
      end

      # The rules in force on a date. Everything else is inert — not skipped
      # silently at evaluation time, just absent from the set being evaluated.
      def effective_on(date)
        @rules.select { |rule| rule.effective_on?(date) }
      end
    end
  end
end
