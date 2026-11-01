# frozen_string_literal: true

module Corvid
  # Classifies one member's medical-frailty evidence against the criteria
  # registered for a state. Conditions, medications, and claims are read
  # through the injected adapter and kept in memory for the call only.
  # Nothing is persisted or logged (ADR 0003).
  #
  # `unknown` when the state is not configured, any of the three reads
  # returns nil, a record is unreadable (`:unreadable_evidence`), or the
  # only would-be matches are undated. Unreadable evidence takes
  # precedence over undated evidence. A dated match inside the window is
  # `likely_frail`; unreadable records are not evidence. Entered-in-error
  # records are ignored before they are read. `not_indicated` only when
  # every read answered and nothing in the lookback matched. A readable
  # condition in another code system is not a match.
  #
  # Codes, code systems, and statuses are normalised before they are
  # validated or compared. The text is read as UTF-8 the same way as
  # registered criteria: an invalid encoding, or one that is not
  # ASCII-compatible, is nil and does not raise. Surrounding Unicode
  # whitespace and invisible format characters are stripped. What remains
  # is nil when it has no visible letter or digit. A nil code, code
  # system, or procedure code is unreadable evidence unless a dated
  # in-window match exists.
  #
  # The result lists each matching category, date, and source type. It
  # has no display text, codes, dosage text, raw references, or patient
  # identifier. Error messages name the problem only.
  class MedicalFrailtyClassifier
    ICD10_CM = "http://hl7.org/fhir/sid/icd-10-cm"
    ENTERED_IN_ERROR = "entered-in-error"
    READS = %i[get_conditions get_medications list_claims].freeze
    # Ends only. Unicode whitespace, ASCII whitespace including NUL, and
    # invisible format characters (U+00A0, U+3000, U+200B). Interior
    # characters stay so code systems and medication codes still compare
    # exactly.
    SURROUNDING_INVISIBLE =
      /\A[[:space:]\p{Cf}\u0000]+|[[:space:]\p{Cf}\u0000]+\z/
    private_constant :SURROUNDING_INVISIBLE

    Result = Struct.new(:status, :reason, :evidence, keyword_init: true) do
      def to_h
        { status:, reason:, evidence: evidence.map(&:to_h) }
      end
    end

    Evidence = Struct.new(:category, :date, :source_type, keyword_init: true) do
      def to_h
        { category:, date:, source_type: }
      end
    end

    def initialize(adapter: Corvid.adapter)
      @adapter = adapter
    end

    def call(patient_identifier:, state_code:, as_of:, lookback_months: 12)
      identifier = require_identifier(patient_identifier)
      date = require_as_of(as_of)
      months = require_lookback(lookback_months)
      criteria = MedicalFrailtyCriteria.lookup(state_code)
      return unknown(:state_not_configured) unless criteria.configured?

      lists = read_lists(identifier)
      return unknown(:source_unavailable) if lists.nil?

      decide(criteria, lists, date, months)
    end

    private

    def require_identifier(value)
      raise ArgumentError, "patient_identifier is missing" unless value.is_a?(String) && !value.strip.empty?

      value
    end

    def require_as_of(value)
      raise ArgumentError, "as_of must be a Date" unless value.instance_of?(Date)

      value.gregorian
    end

    def require_lookback(value)
      raise ArgumentError, "lookback_months must be a positive Integer" unless positive_integer?(value)

      value
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def read_lists(patient_identifier)
      lists = READS.map { |name| @adapter.public_send(name, patient_identifier) }
      lists if lists.all?(Array)
    end

    def decide(criteria, lists, as_of, months)
      rows = []
      summaries = collect(criteria, lists, as_of, months, rows)
      return likely(rows) unless rows.empty?

      reason = failure_reason(summaries)
      return unknown(reason) if reason

      no_evidence
    end

    def collect(criteria, lists, as_of, months, rows)
      window = [ as_of.prev_month(months), as_of ]
      conditions, medications, claims = lists
      [
        scan_conditions(criteria, conditions, window, rows),
        scan_medications(criteria, medications, window, rows),
        scan_claims(criteria, claims, window, rows)
      ]
    end

    # Unreadable outranks undated when no dated in-window match was kept.
    def failure_reason(summaries)
      return :unreadable_evidence if summaries.any? { |summary| summary[:unreadable] }
      return :undated_evidence if summaries.any? { |summary| summary[:undated] }

      nil
    end

    def scan_conditions(criteria, conditions, window, rows)
      scan(conditions) { |condition| add_condition(criteria, condition, window, rows) }
    end

    def scan_medications(criteria, medications, window, rows)
      scan(medications) { |medication| add_medication(criteria, medication, window, rows) }
    end

    def scan_claims(criteria, claims, window, rows)
      scan(claims) { |claim| add_claim(criteria, claim, window, rows) }
    end

    def scan(items)
      items.each_with_object({}) { |item, flags| flag_outcome(flags, yield(item)) }
    end

    def flag_outcome(flags, outcome)
      case outcome
      when :undated, :unreadable
        flags[outcome] = true
      end
    end

    def add_condition(criteria, condition, window, rows)
      return :unreadable unless condition.is_a?(ConditionReference)
      return if entered_in_error?(condition.clinical_status)

      code = stripped_text(condition.code)
      system = stripped_text(condition.code_system)
      return :unreadable unless readable_condition?(code, system)
      return unless system == ICD10_CM

      names = category_names(criteria) { |category| icd10_match?(category, code) }
      return if names.empty?

      record(names, condition.onset_date, :condition, window, rows)
    end

    def add_medication(criteria, medication, window, rows)
      return :unreadable unless medication.is_a?(MedicationReference)
      return if entered_in_error?(medication.status)

      code = stripped_text(medication.code)
      system = stripped_text(medication.code_system)
      return :unreadable if code.nil? || system.nil?

      names = category_names(criteria) { |category| medication_match?(category, system, code) }
      return if names.empty?

      record(names, medication.authored_on, :medication, window, rows)
    end

    def add_claim(criteria, claim, window, rows)
      return :unreadable unless claim.is_a?(ClaimLineReference)
      return :unreadable if token_key(claim.procedure_code).nil?

      names = category_names(criteria) { |category| procedure_match?(category, claim.procedure_code) }
      return if names.empty?

      record(names, claim.serviced_date, :claim, window, rows)
    end

    # A non-blank code and system are readable. ICD-10-CM also requires a
    # real ICD-10 shape; another code system does not.
    def readable_condition?(code, system)
      return false if code.nil? || system.nil?
      return true unless system == ICD10_CM

      !icd10_body(code).nil?
    end

    def category_names(criteria)
      criteria.categories.filter_map { |name, category| name if yield(category) }
    end

    def icd10_match?(category, code)
      body = icd10_body(code)
      return false if body.nil?

      category.icd10_prefixes.any? { |prefix| prefix_hit?(body, prefix) }
    end

    def prefix_hit?(body, prefix)
      prefix_body = icd10_body(prefix)
      !prefix_body.nil? && body.start_with?(prefix_body)
    end

    def medication_match?(category, system, code)
      category.medication_codes.any? do |expected|
        expected[:system] == system && expected[:code] == code
      end
    end

    def procedure_match?(category, code)
      key = token_key(code)
      return false if key.nil?

      category.procedure_codes.any? { |expected| token_key(expected) == key }
    end

    def record(names, raw_date, source_type, window, rows)
      date = evidence_date(raw_date)
      return :undated if date.nil?
      return unless covered?(date, window)

      names.each { |name| rows << Evidence.new(category: name, date:, source_type:) }
      :dated
    end

    def covered?(date, window)
      start_on, end_on = window
      date >= start_on && date <= end_on
    end

    def evidence_date(value)
      return value.gregorian if value.instance_of?(Date)
      return Date.new(value.year, value.month, value.day) if time_like?(value)

      nil
    end

    def time_like?(value)
      value.is_a?(Time) || date_time?(value) || zone_time?(value)
    end

    def date_time?(value)
      defined?(DateTime) && value.is_a?(DateTime)
    end

    def zone_time?(value)
      defined?(ActiveSupport::TimeWithZone) && value.is_a?(ActiveSupport::TimeWithZone)
    end

    def entered_in_error?(status)
      text = stripped_text(status)
      !text.nil? && text.casecmp?(ENTERED_IN_ERROR)
    end

    def icd10_body(value)
      text = stripped_text(value)
      return if text.nil?

      body = text.upcase(:ascii).delete(".")
      body if MedicalFrailtyCriteria::ICD10_PREFIX.match?(body)
    end

    def token_key(value)
      text = stripped_text(value)
      return if text.nil?

      key = text.upcase(:ascii)
      key if MedicalFrailtyCriteria::CODE_TOKEN.match?(key)
    end

    # Nil for a non-String, text that cannot be read as UTF-8, or text
    # with no visible letter or digit after surrounding Unicode whitespace
    # and format characters are removed. Never raises. Callers fail closed
    # on nil.
    def stripped_text(value)
      return unless value.is_a?(String)

      # Copy first so a subclass cannot override the encoding read.
      text = MedicalFrailtyCriteria.utf8_text(String.new(value))
      return if text.nil?

      trimmed = text.gsub(SURROUNDING_INVISIBLE, "")
      trimmed unless MedicalFrailtyCriteria.blank_text?(trimmed)
    end

    def likely(rows)
      finish(:likely_frail, nil, sort_evidence(rows))
    end

    def unknown(reason)
      finish(:unknown, reason, [])
    end

    def no_evidence
      finish(:not_indicated, nil, [])
    end

    def sort_evidence(rows)
      rows.sort_by { |row| [ row.date, row.source_type.to_s, row.category ] }
    end

    def finish(status, reason, evidence)
      Result.new(status:, reason:, evidence: evidence.each(&:freeze).freeze).freeze
    end
  end
end
