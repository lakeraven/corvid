# frozen_string_literal: true

module Corvid
  # Per-state medical-frailty criteria. Each category lists ICD-10-CM
  # prefixes, medication system/code pairs, and CPT/HCPCS codes.
  #
  # The engine ships no states. Hosts register them from an initializer:
  #
  #   Corvid::MedicalFrailtyCriteria.register(
  #     "XA",
  #     categories: {
  #       example: {
  #         icd10_prefixes: [ "E10" ],
  #         medication_codes: [],
  #         procedure_codes: []
  #       }
  #     }
  #   )
  #
  # Lookup of an unregistered or malformed code returns NotConfigured.
  # Callers must not treat that as "no frailty criteria".
  #
  # ICD-10 prefixes, procedure codes, and medication systems and codes
  # are cleaned with .clean_text before they are validated or stored.
  # That is the same rule the classifier uses for adapter values. A blank
  # result is rejected. A medication system or code that still contains
  # whitespace or a control character is rejected. URI shape and code
  # shape are checked on the cleaned value.
  #
  # Registration errors name the problem only. They do not include the
  # supplied state, category, or code (ADR 0003).
  module MedicalFrailtyCriteria
    # Two ASCII letters, checked before ASCII-upcasing. Stored codes are uppercase UTF-8.
    # Same rule as StateMedicaidRules, so "ß" and "ﬀ" cannot alias a state.
    STATE_CODE = /\A[A-Za-z]{2}\z/
    # ICD-10-CM prefix with the decimal removed: a letter, a digit, then
    # up to five more letters or digits (seven characters at most).
    ICD10_PREFIX = /\A[A-Z][0-9][0-9A-Z]{0,5}\z/
    # CPT, HCPCS, NDC, and short synthetic tokens. A letter or digit,
    # then letters, digits, underscores, or hyphens, 20 characters at most.
    # Longer text is not a code.
    CODE_TOKEN = /\A[A-Z0-9][A-Z0-9_-]{0,19}\z/
    SYSTEM_URI = /\A(?:https?:\/\/|urn:)[^\s]+\z/i
    CATEGORY_FIELDS = %w[icd10_prefixes medication_codes procedure_codes].freeze
    MEDICATION_FIELDS = %w[system code].freeze
    # A character that is actually visible. Hangul fillers are letters by
    # category but render as nothing, so they do not count. Same set as
    # StateMedicaidRules.
    VISIBLE = /[\p{L}\p{N}&&[^\u115F\u1160\u3164\uFFA0]]/
    # Ends only. Unicode whitespace and invisible format characters
    # (no-break space, ideographic space, zero-width space). Interior
    # characters stay. NUL is a control character, not whitespace or
    # format, so it is left in place and medication registration rejects it.
    SURROUNDING_INVISIBLE =
      /\A[[:space:]\p{Cf}]+|[[:space:]\p{Cf}]+\z/
    # Whitespace or a control character still inside a cleaned medication
    # system or code. Those values compare exactly, so they are not stored.
    # Alternation, not one character class: [[:space:]] already includes
    # some Cc characters, and Ruby warns on that duplicated range.
    WHITESPACE_OR_CONTROL = /[[:space:]]|\p{Cc}/
    private_constant :SURROUNDING_INVISIBLE, :WHITESPACE_OR_CONTROL

    Entry = Struct.new(:state_code, :categories, keyword_init: true) do
      def configured? = true
    end

    Category = Struct.new(:icd10_prefixes, :medication_codes, :procedure_codes, keyword_init: true)

    NotConfigured = Struct.new(:state_code, keyword_init: true) do
      def configured? = false
    end

    class << self
      def register(state_code, categories:)
        code = normalize_state_code(state_code)
        entry = build_entry(code, categories)
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

      # Public so an adapter value and a registered value share one UTF-8
      # read. Nil when the encoding is invalid or not ASCII-compatible.
      # ASCII-8BIT is nil when it contains a non-ASCII byte.
      def utf8_text(text)
        return unless text.valid_encoding? && text.encoding.ascii_compatible?
        return if text.encoding == Encoding::ASCII_8BIT && !text.ascii_only?

        text.encode(Encoding::UTF_8)
      rescue EncodingError
        nil
      end

      # Public so "no visible letter or digit" is the same rule as a
      # category key. Hangul fillers do not count.
      def blank_text?(text)
        !VISIBLE.match?(text)
      end

      # Public so registration and the classifier share one cleaning rule
      # and cannot drift. Nil for a non-String, text that cannot be read
      # as UTF-8, or text with no visible letter or digit after surrounding
      # Unicode whitespace and format characters are removed. Never raises.
      # Control characters such as NUL are not removed.
      def clean_text(value)
        text = copied_text(value)
        return if text.nil?

        trimmed = text.gsub(SURROUNDING_INVISIBLE, "")
        trimmed unless blank_text?(trimmed)
      end

      # Public so registration and the classifier share one check and
      # cannot drift. True when text contains whitespace or a control
      # character. Callers clean with .clean_text first.
      def whitespace_or_control?(text)
        WHITESPACE_OR_CONTROL.match?(text)
      end

      private

      def entries
        @entries ||= {}
      end

      def not_configured(state_code)
        NotConfigured.new(state_code: freeze_copy(state_code)).freeze
      end

      def build_entry(code, categories)
        Entry.new(state_code: code, categories: build_categories(categories)).freeze
      end

      def build_categories(categories)
        raise ArgumentError, "categories must be a non-empty Hash" unless categories.is_a?(Hash) && !categories.empty?

        seen = {}
        categories.each_with_object({}) do |(name, attrs), built|
          built[category_key(name, seen)] = build_category(attrs)
        end.freeze
      end

      def build_category(attrs)
        category = new_category(category_fields(attrs))
        raise ArgumentError, "category must include a code" if empty_category?(category)

        category
      end

      def new_category(fields)
        Category.new(
          icd10_prefixes: code_list(fields[:icd10_prefixes]) { |item| store_icd10(item) },
          medication_codes: code_list(fields[:medication_codes]) { |item| store_medication(item) },
          procedure_codes: code_list(fields[:procedure_codes]) { |item| store_procedure(item) }
        ).freeze
      end

      def empty_category?(category)
        [
          category.icd10_prefixes,
          category.medication_codes,
          category.procedure_codes
        ].all?(&:empty?)
      end

      def code_list(value)
        raise ArgumentError, "code list must be an Array" unless value.is_a?(Array)

        value.map { |item| yield(item) }.freeze
      end

      def category_fields(attrs)
        fields = field_map(attrs, CATEGORY_FIELDS, "category must be a Hash")
        return fields if CATEGORY_FIELDS.all? { |name| fields.key?(name.to_sym) }

        raise ArgumentError, "category is missing a field"
      end

      def medication_fields(entry)
        fields = field_map(entry, MEDICATION_FIELDS, "medication code must be a Hash")
        return fields if fields.key?(:system) && fields.key?(:code)

        raise ArgumentError, "medication code must include a system and a code"
      end

      def field_map(value, allowed, type_message)
        raise ArgumentError, type_message unless value.is_a?(Hash)

        seen = {}
        value.each_with_object({}) do |(key, field_value), fields|
          fields[field_name(key, allowed, seen).to_sym] = field_value
        end
      end

      def field_name(key, allowed, seen)
        name = key_text(key)
        raise ArgumentError, "field must be a String or Symbol" if name.nil?
        raise ArgumentError, "unknown field" unless allowed.include?(name)
        raise ArgumentError, "duplicate field" if seen.key?(name)

        seen[name] = true
        name
      end

      def category_key(key, seen)
        name = key_text(key)
        raise ArgumentError, "category key must be a String or Symbol" if name.nil?
        raise ArgumentError, "category key is blank" if blank_text?(name)
        raise ArgumentError, "duplicate category" if seen.key?(name)

        seen[name] = true
        name.freeze
      end

      def store_icd10(value)
        text = clean_text(value)
        raise ArgumentError, "icd10 prefix is not usable" if icd10_body(text).nil?

        text.freeze
      end

      def store_procedure(value)
        store_token(value, "procedure code is not usable")
      end

      def store_medication(entry)
        fields = medication_fields(entry)
        system = store_system(fields[:system])
        code = store_medication_code(fields[:code])
        { system:, code: }.freeze
      end

      def store_system(value)
        text = clean_text(value)
        raise ArgumentError, "medication system is not usable" unless usable_medication_system?(text)

        text.freeze
      end

      def store_medication_code(value)
        text = clean_text(value)
        raise ArgumentError, "medication code is not usable" unless usable_medication_code?(text)

        text.freeze
      end

      def store_token(value, message)
        text = clean_text(value)
        raise ArgumentError, message if token_key(text).nil?

        text.freeze
      end

      # SYSTEM_URI rejects whitespace, not control characters. A trailing
      # NUL still matches [^\s], so it has to be rejected on its own.
      def usable_medication_system?(text)
        return false if text.nil? || whitespace_or_control?(text)

        text.match?(SYSTEM_URI)
      end

      def usable_medication_code?(text)
        return false if text.nil? || whitespace_or_control?(text)

        !token_key(text).nil?
      end

      def icd10_body(text)
        return if text.nil?

        body = text.upcase(:ascii).delete(".")
        body if ICD10_PREFIX.match?(body)
      end

      def token_key(text)
        return if text.nil?

        key = text.upcase(:ascii)
        key if CODE_TOKEN.match?(key)
      end

      # Copy first so a subclass cannot override the encoding read.
      def copied_text(value)
        return unless value.is_a?(String)

        utf8_text(String.new(value))
      end

      def key_text(key)
        raw = raw_key(key)
        utf8_text(raw) if raw
      end

      def raw_key(key)
        return String.new(key.name) if key.is_a?(Symbol)

        String.new(key) if key.is_a?(String)
      end

      def normalize_state_code(state_code)
        code = canonical_state_code(state_code)
        return code if code

        raise ArgumentError, "state_code must be two letters"
      end

      # Full Unicode upcase maps "ß" to "SS" and "ﬀ" to "FF". Validate the
      # raw characters first, then ASCII-upcase, so those cannot alias a state.
      # Read the string's own bytes, or Symbol#name. String#to_s can be
      # overridden and would alias another state. An incompatible encoding
      # is not a state code, so lookup fails closed instead of raising.
      def canonical_state_code(state_code)
        raw = state_code_characters(state_code)
        return if raw.nil?
        return unless raw.valid_encoding? && raw.encoding.ascii_compatible?
        return unless STATE_CODE.match?(raw)

        raw.upcase(:ascii).encode(Encoding::UTF_8).freeze
      end

      def state_code_characters(state_code)
        return state_code.name if state_code.is_a?(Symbol)

        String.new(state_code) if state_code.is_a?(String)
      end

      def presented_state_code(state_code)
        return state_code if state_code.is_a?(String)

        state_code.name if state_code.is_a?(Symbol)
      end

      def freeze_copy(value)
        value.is_a?(String) ? value.dup.freeze : value
      end
    end
  end
end
