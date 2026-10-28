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
  #
  # A description_pattern must identify a specific program. A pattern that
  # matches the empty string, or any of the sentinels "a", "Z", and "0",
  # is rejected.
  module StateMedicaidRules
    GROUPS = %w[expansion_adult waiver_adult other].freeze
    GROUP_FIELDS = %w[renewal_months retro_coverage_months work_requirement].freeze
    PROGRAM_FIELDS = %w[code description_pattern].freeze
    # Two ASCII letters, checked before ASCII-upcasing. Stored codes are uppercase UTF-8.
    STATE_CODE = /\A[A-Za-z]{2}\z/

    # Shared by plan descriptions and program codes. Text is read as UTF-8;
    # text that cannot be (binary with high bytes, an invalid or
    # ASCII-incompatible encoding) is unreadable. Text with no letter or
    # digit is blank, which covers Unicode spaces, controls, format
    # characters and soft hyphens. Hangul fillers are letters by category
    # but render as nothing, so they do not count.
    module ReadableText
      VISIBLE = /[\p{L}\p{N}&&[^\u115F\u1160\u3164\uFFA0]]/

      module_function

      # The text as UTF-8, or nil when it cannot be read.
      def utf8_text(text)
        return unless text.encoding.ascii_compatible? && text.valid_encoding?
        return if text.encoding == Encoding::ASCII_8BIT && !text.ascii_only?

        text.encode(Encoding::UTF_8)
      rescue EncodingError
        nil
      end

      def blank?(text)
        !VISIBLE.match?(text)
      end
    end
    private_constant :ReadableText
    extend ReadableText

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
      include ReadableText

      def configured? = true

      def expanded? = expanded

      def group(name)
        key = group_name(name)
        unless GROUPS.include?(key)
          raise ArgumentError, "unknown eligibility group #{name.inspect}"
        end

        groups[key]
      end

      # Nil, blank, or unreadable text is undetermined, not "no waiver".
      # Name the problem only; the text may be member plan data.
      def waiver_program_for(description)
        text = plan_description(description)
        work_requirement_programs.find do |program|
          program.description_pattern.match?(text)
        rescue Encoding::CompatibilityError
          raise ArgumentError, "description encoding is incompatible"
        end
      end

      private

      # Read the string's own characters, or Symbol#name. String#to_s can be
      # overridden and would resolve a different eligibility group.
      def group_name(name)
        return name.name if name.is_a?(Symbol)

        String.new(name) if name.is_a?(String)
      end

      def plan_description(description)
        unless description.is_a?(String)
          raise ArgumentError, "description must be a String"
        end

        text = utf8_text(String.new(description))
        raise ArgumentError, "description encoding is incompatible" unless text
        raise ArgumentError, "description is blank" if blank?(text)

        text
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

        not_configured(presented_state_code(state_code))
      end

      def state_codes
        entries.keys.sort
      end

      def reset!
        @entries = {}
      end

      # Own characters of a String (including a subclass), or Symbol#name.
      # Anything else is not a code and comes back nil. case/when uses
      # Module#===, which a caller cannot override via is_a?, so a spoofed
      # is_a?, name, to_s, or to_str cannot alias another state. Lookup
      # still fails closed for those values; this only exposes the read
      # lookup already uses.
      def state_code_characters(state_code)
        case state_code
        when Symbol then Symbol.instance_method(:name).bind_call(state_code)
        when String then String.new(state_code)
        end
      end

      private

      def entries
        @entries ||= {}
      end

      def not_configured(state_code)
        NotConfigured.new(state_code: freeze_copy(state_code)).freeze
      end

      def build_entry(code, expanded, groups, programs)
        expanded_flag = require_boolean(expanded, "expanded")
        built_groups = build_groups(groups)
        reject_unexpanded_expansion_group(expanded_flag, built_groups)
        reject_waiver_without_programs(built_groups, programs)
        Entry.new(
          state_code: code,
          expanded: expanded_flag,
          groups: built_groups,
          work_requirement_programs: build_programs(programs)
        ).freeze
      end

      def reject_unexpanded_expansion_group(expanded, groups)
        return if expanded
        return unless groups.key?("expansion_adult")

        raise ArgumentError, "expansion_adult cannot be registered when expanded is false"
      end

      def reject_waiver_without_programs(groups, programs)
        waiver = groups["waiver_adult"]
        return unless waiver && waiver.work_requirement?
        return unless programs_missing?(programs)

        raise ArgumentError, "waiver_adult work_requirement requires work_requirement_programs"
      end

      def programs_missing?(programs)
        programs.nil? || (programs.is_a?(Array) && programs.empty?)
      end

      # Accept symbol- or string-keyed hashes (initializers, YAML, JSON).
      # Unknown keys, duplicate keys, and non-String/Symbol keys raise
      # ArgumentError at registration so a host finds out at boot rather
      # than when a member's coverage is evaluated.
      def build_groups(groups)
        unless groups.is_a?(Hash) && !groups.empty?
          raise ArgumentError, "groups must be a non-empty Hash, got #{groups.inspect}"
        end

        seen = {}
        groups.each_with_object({}) do |(name, attrs), built|
          key = normalize_key(name, GROUPS, seen, "eligibility group")
          built[key] = build_group(key, attrs)
        end.freeze
      end

      def build_group(name, attrs)
        fields = normalize_fields(attrs, "group #{name}", GROUP_FIELDS)
        Group.new(
          renewal_months: positive_integer(fields[:renewal_months], "group #{name} :renewal_months"),
          retro_coverage_months: non_negative_integer(
            fields[:retro_coverage_months],
            "group #{name} :retro_coverage_months"
          ),
          work_requirement: require_boolean(fields[:work_requirement], "group #{name} :work_requirement")
        ).freeze
      end

      def build_programs(programs)
        unless programs.is_a?(Array)
          raise ArgumentError, "work_requirement_programs must be an Array, got #{programs.class}"
        end

        seen = {}
        programs.map do |program|
          built = build_program(program)
          code = built.code
          if seen.include?(code)
            raise ArgumentError, "duplicate work requirement program code #{code.inspect}"
          end

          seen[code] = true
          built
        end.freeze
      end

      def build_program(program)
        fields = normalize_fields(program, "work requirement program", PROGRAM_FIELDS)
        WorkRequirementProgram.new(
          code: program_code(fields[:code]),
          description_pattern: description_pattern(fields[:description_pattern])
        ).freeze
      end

      def normalize_fields(value, label, allowed)
        unless value.is_a?(Hash)
          raise ArgumentError, "#{label} must be a Hash, got #{value.class}"
        end

        seen = {}
        value.each_with_object({}) do |(key, field_value), fields|
          name = normalize_key(key, allowed, seen, label)
          fields[name.to_sym] = field_value
        end
      end

      # Group names, group fields, and program fields share one normalised
      # form so a Symbol and its String cannot collapse last-wins.
      def normalize_key(key, allowed, seen, label)
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise ArgumentError, "#{label} key must be a String or Symbol, got #{key.inspect}"
        end

        name = key.to_s.dup
        unless allowed.include?(name)
          raise ArgumentError, "unknown #{label} #{key.inspect}"
        end
        if seen.include?(name)
          raise ArgumentError, "duplicate #{label} #{key.inspect}"
        end

        seen[name.freeze] = true
        name
      end

      def normalize_state_code(state_code)
        code = canonical_state_code(state_code)
        return code if code

        raise ArgumentError, "state_code must be two letters, got #{state_code.inspect}"
      end

      # Full Unicode upcase maps "ß" to "SS" and "ﬀ" to "FF". Validate the
      # raw characters first, then ASCII-upcase, so those cannot alias a state.
      # Read the string's own bytes, or Symbol#name. String#to_s can be
      # overridden and would alias another state. An incompatible encoding
      # is not a state code, so lookup fails closed instead of raising.
      # Re-encode after validation: upcase keeps the caller encoding, so a
      # binary code would otherwise stay ASCII-8BIT in the registry.
      def canonical_state_code(state_code)
        raw = state_code_characters(state_code)
        return if raw.nil?
        return unless raw.valid_encoding? && raw.encoding.ascii_compatible?
        return unless STATE_CODE.match?(raw)

        raw.upcase(:ascii).encode(Encoding::UTF_8).freeze
      end

      # Characters of a value that is not two ASCII letters, from
      # state_code_characters, so a caller is_a? is not consulted again.
      # A string is copied later. Anything else is not a state code.
      def presented_state_code(state_code)
        state_code_characters(state_code)
      end

      def freeze_copy(value)
        value.is_a?(String) ? value.dup.freeze : value
      end

      def positive_integer(value, label)
        return value if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{label} must be a positive Integer, got #{value.inspect}"
      end

      # Zero is a real window: the state has no retroactive coverage.
      def non_negative_integer(value, label)
        return value if value.is_a?(Integer) && value >= 0

        raise ArgumentError, "#{label} must be a non-negative Integer, got #{value.inspect}"
      end

      def require_boolean(value, label)
        return value if value == true || value == false

        raise ArgumentError, "#{label} must be true or false, got #{value.inspect}"
      end

      def program_code(code)
        text = utf8_text(String.new(code)) if code.is_a?(String)
        unless text && !blank?(text)
          raise ArgumentError, "work requirement program :code must be a non-empty String, got #{code.inspect}"
        end

        text.freeze
      end

      def description_pattern(pattern)
        unless pattern.is_a?(Regexp)
          raise ArgumentError, "description_pattern must be a Regexp, got #{pattern.class}"
        end
        # A pattern that matches "" matches every description, so every plan
        # would be classified as that waiver. Matching a sentinel ("a", "Z",
        # or "0") means the pattern does not identify a specific program.
        if pattern.match?("")
          raise ArgumentError, "description_pattern must not match an empty string"
        end
        if catch_all_description_pattern?(pattern)
          raise ArgumentError, "description_pattern must identify a specific program"
        end

        pattern.dup.freeze
      end

      def catch_all_description_pattern?(pattern)
        %w[a Z 0].any? { |sentinel| pattern.match?(sentinel) }
      end
    end
  end
end
