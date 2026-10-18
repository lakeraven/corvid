# frozen_string_literal: true

module Corvid
  # Registry of per-state Medicaid rules. Each state declares whether it
  # expanded Medicaid, the waiver programs whose adults carry a work
  # requirement, and — for each eligibility group — the renewal cycle,
  # retroactive coverage window, and whether the work requirement applies.
  #
  # The engine ships no states. Hosts register them from an initializer:
  #
  #   Corvid::StateMedicaidRules.register(
  #     "XA",
  #     expanded: true,
  #     groups: {
  #       expansion_adult: {
  #         renewal_months: 12,
  #         retro_coverage_months: 3,
  #         work_requirement: false
  #       }
  #     }
  #   )
  #
  # Lookup of an unregistered or malformed code returns NotConfigured.
  # An unconfigured state means the rules are undetermined (fail closed):
  # callers must not apply a default expansion flag, renewal cycle, or
  # work requirement.
  module StateMedicaidRules
    GROUPS = %w[expansion_adult waiver_adult other].freeze
    STATE_CODE = /\A[A-Z]{2}\z/

    Group = Struct.new(
      :renewal_months,
      :retro_coverage_months,
      :work_requirement,
      keyword_init: true
    ) do
      def work_requirement? = work_requirement
    end

    WorkRequirementProgram = Struct.new(:code, :description_pattern, keyword_init: true)

    Entry = Struct.new(
      :state_code,
      :expanded,
      :groups,
      :work_requirement_programs,
      keyword_init: true
    ) do
      def configured? = true

      def expanded? = expanded

      def group(name)
        key = name.to_s
        unless GROUPS.include?(key)
          raise ArgumentError, "unknown eligibility group #{name.inspect}"
        end

        groups[key]
      end

      def waiver_program_for(description)
        text = description.to_s
        return if text.strip.empty?

        work_requirement_programs.find { |program| program.description_pattern.match?(text) }
      end
    end

    NotConfigured = Struct.new(:state_code, keyword_init: true) do
      def configured? = false
    end

    class << self
      def register(state_code, expanded:, groups:, work_requirement_programs: [])
        code = normalize_state_code(state_code)
        entry = build_entry(code, expanded, groups, work_requirement_programs)
        entries[code] = entry
        entry
      end

      def lookup(state_code)
        code = canonical_state_code(state_code)
        return entries[code] || not_configured(code) if code

        not_configured(state_code)
      end

      def state_codes
        entries.keys.sort
      end

      def reset!
        @entries = {}
      end

      private

      def entries
        @entries ||= {}
      end

      def not_configured(state_code)
        NotConfigured.new(state_code: freeze_copy(state_code)).freeze
      end

      def build_entry(code, expanded, groups, programs)
        Entry.new(
          state_code: code,
          expanded: require_boolean(expanded, "expanded"),
          groups: build_groups(groups),
          work_requirement_programs: build_programs(programs)
        ).freeze
      end

      # Accept symbol- or string-keyed hashes (initializers, YAML, JSON).
      # Invalid input raises ArgumentError at registration so a host finds
      # out at boot rather than when a member's coverage is evaluated.
      def build_groups(groups)
        unless groups.is_a?(Hash) && !groups.empty?
          raise ArgumentError, "groups must be a non-empty Hash, got #{groups.inspect}"
        end

        groups.each_with_object({}) do |(name, attrs), built|
          key = normalize_group_name(name)
          built[key] = build_group(key, attrs)
        end.freeze
      end

      def normalize_group_name(name)
        key = name.to_s
        return key.dup.freeze if GROUPS.include?(key)

        raise ArgumentError, "unknown eligibility group #{name.inspect}"
      end

      def build_group(name, attrs)
        fields = symbolize_hash(attrs, "group #{name}")
        Group.new(
          renewal_months: month_count(fields, name, :renewal_months),
          retro_coverage_months: month_count(fields, name, :retro_coverage_months),
          work_requirement: require_boolean(fields[:work_requirement], "group #{name} :work_requirement")
        ).freeze
      end

      def month_count(fields, name, field)
        positive_integer(fields[field], "group #{name} :#{field}")
      end

      def build_programs(programs)
        unless programs.is_a?(Array)
          raise ArgumentError, "work_requirement_programs must be an Array, got #{programs.class}"
        end

        programs.map { |program| build_program(program) }.freeze
      end

      def build_program(program)
        fields = symbolize_hash(program, "work requirement program")
        WorkRequirementProgram.new(
          code: program_code(fields[:code]),
          description_pattern: description_pattern(fields[:description_pattern])
        ).freeze
      end

      def symbolize_hash(value, label)
        unless value.is_a?(Hash)
          raise ArgumentError, "#{label} must be a Hash, got #{value.class}"
        end

        value.transform_keys(&:to_sym)
      end

      def normalize_state_code(state_code)
        code = canonical_state_code(state_code)
        return code if code

        raise ArgumentError, "state_code must be two letters, got #{state_code.inspect}"
      end

      def canonical_state_code(state_code)
        return unless state_code.is_a?(String) || state_code.is_a?(Symbol)

        code = state_code.to_s.upcase
        code.dup.freeze if STATE_CODE.match?(code)
      end

      def freeze_copy(value)
        value.is_a?(String) ? value.dup.freeze : value
      end

      def positive_integer(value, label)
        return value if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{label} must be a positive Integer, got #{value.inspect}"
      end

      def require_boolean(value, label)
        return value if value == true || value == false

        raise ArgumentError, "#{label} must be true or false, got #{value.inspect}"
      end

      def program_code(code)
        unless code.is_a?(String) && !code.empty?
          raise ArgumentError, "work requirement program :code must be a non-empty String, got #{code.inspect}"
        end

        code.dup.freeze
      end

      def description_pattern(pattern)
        unless pattern.is_a?(Regexp)
          raise ArgumentError, "description_pattern must be a Regexp, got #{pattern.inspect}"
        end

        pattern.dup.freeze
      end
    end
  end
end
