# frozen_string_literal: true

module Corvid
  # Classifies one member's medical-frailty evidence against the criteria
  # registered for a state. Conditions, medications, and claims are read
  # through the injected adapter and kept in memory for the call only.
  # Nothing is persisted or logged (ADR 0003).
  #
  # `unknown` when the state is not configured, any of the three reads
  # returns nil, or the only would-be matches are undated. `not_indicated`
  # only when every read answered and nothing in the lookback matched.
  #
  # The result lists each matching category, date, and source type. It
  # has no display text, codes, dosage text, raw references, or patient
  # identifier. Error messages name the problem only.
  class MedicalFrailtyClassifier
    ICD10_CM = "http://hl7.org/fhir/sid/icd-10-cm"
    ENTERED_IN_ERROR = "entered-in-error"
    READS = %i[get_conditions get_medications list_claims].freeze

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
      undated = collect(criteria, lists, as_of, months, rows)
      return likely(rows) unless rows.empty?
      return unknown(:undated_evidence) if undated

      no_evidence
    end

    def collect(criteria, lists, as_of, months, rows)
      window = [ as_of.prev_month(months), as_of ]
      conditions, medications, claims = lists
      [
        scan_conditions(criteria, conditions, window, rows),
        scan_medications(criteria, medications, window, rows),
        scan_claims(criteria, claims, window, rows)
      ].any?
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
      undated = false
      items.each { |item| undated = true if yield(item) == :undated }
      undated
    end

    def add_condition(criteria, condition, window, rows)
      return unless condition.is_a?(ConditionReference)
      return if entered_in_error?(condition.clinical_status)
      return unless condition.code_system == ICD10_CM

      names = category_names(criteria) { |category| icd10_match?(category, condition.code) }
      return if names.empty?

      record(names, condition.onset_date, :condition, window, rows)
    end

    def add_medication(criteria, medication, window, rows)
      return unless medication.is_a?(MedicationReference)
      return if entered_in_error?(medication.status)

      names = category_names(criteria) { |category| medication_match?(category, medication) }
      return if names.empty?

      record(names, medication.authored_on, :medication, window, rows)
    end

    def add_claim(criteria, claim, window, rows)
      return unless claim.is_a?(ClaimLineReference)

      names = category_names(criteria) { |category| procedure_match?(category, claim.procedure_code) }
      return if names.empty?

      record(names, claim.serviced_date, :claim, window, rows)
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

    def medication_match?(category, medication)
      category.medication_codes.any? do |expected|
        expected[:system] == medication.code_system && expected[:code] == medication.code
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
      status.is_a?(String) && status.casecmp?(ENTERED_IN_ERROR)
    end

    def icd10_body(value)
      return unless value.is_a?(String)

      body = value.upcase(:ascii).delete(".")
      body if MedicalFrailtyCriteria::ICD10_PREFIX.match?(body)
    end

    def token_key(value)
      return unless value.is_a?(String)

      key = value.upcase(:ascii)
      key if MedicalFrailtyCriteria::CODE_TOKEN.match?(key)
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
