# frozen_string_literal: true

module Corvid
  # Records the Medicaid eligibility group on a medicaid alternate-resource
  # check. A group stated on the coverage hash is kept with its source.
  # A nil or blank group is not a statement; the group is then inferred
  # from state rules, age on the date of service, and a waiver plan
  # description. Ambiguity is recorded as "unknown" — never a guess.
  #
  # Precedence is decided under a row lock on a fresh read. A stale
  # in-memory copy cannot overwrite a staff entry, and an inference
  # cannot overwrite a stated group.
  #
  # Coverage may state only eligibility_response, state_case_data, or
  # registration. Any other source is recorded as eligibility_response.
  #
  # The check's referral must be visible in the current tenant (ADR 0002)
  # or nothing is written. Age is computed in memory from the adapter
  # patient. The date of birth is never stored, logged, or placed in an
  # error message (ADR 0003).
  class MedicaidEligibilityGroupService
    # Whole years on the date of service. 19 through 64 with no waiver
    # match in an expansion state is expansion_adult. A waiver-program
    # match inside that band is waiver_adult. Outside the band is other,
    # unless a waiver match disagrees, which is unknown.
    ADULT_MIN_AGE = 19
    ADULT_MAX_AGE = 64

    # Adapter coverage cannot claim staff_entry or inferred.
    STATED_SOURCES = %w[eligibility_response state_case_data registration].freeze

    def initialize(adapter:)
      @adapter = adapter
    end

    def record!(check, coverage:, date_of_service:)
      return unless medicaid?(check)
      return unless referral_visible?(check)

      # Fresh instance: with_lock refuses a row that already has unsaved
      # changes, and those changes are the stale copy we must ignore.
      row = check.class.find(check.id)
      row.with_lock { apply_precedence(row, coverage_hash(coverage), date_of_service) }
    end

    def record_staff_entry!(check, eligibility_group:)
      ensure_staff_writable!(check)
      group = required_group(eligibility_group)
      row = check.class.find(check.id)
      row.with_lock { write!(row, group, "staff_entry") }
    end

    private

    def medicaid?(check)
      check.resource_type == "medicaid"
    end

    def ensure_staff_writable!(check)
      raise ArgumentError, "eligibility group is only recorded for medicaid" unless medicaid?(check)
      raise ArgumentError, "eligibility group cannot be recorded" unless referral_visible?(check)
    end

    def required_group(value)
      group = recognized(value, AlternateResourceCheck::ELIGIBILITY_GROUPS)
      raise ArgumentError, "eligibility_group is not recognized" unless group

      group
    end

    # TenantScoped default scope hides other tenants and raises when no
    # tenant is set. Either result means the referral is not visible.
    def referral_visible?(check)
      Corvid::PrcReferral.where(id: check.prc_referral_id).exists?
    rescue Corvid::MissingTenantContextError
      false
    end

    def coverage_hash(coverage)
      coverage.is_a?(Hash) ? coverage : {}
    end

    # with_lock has reloaded this row. Decide from that read, then write
    # before the lock is released.
    def apply_precedence(row, coverage, date_of_service)
      return unless medicaid?(row)
      return current_group(row) if staff_entry?(row)
      return write_stated!(row, coverage) if stated?(coverage)
      return current_group(row) if preserved?(row)

      write!(row, inferred_group(row, coverage, date_of_service), "inferred")
    end

    def staff_entry?(check)
      check.eligibility_group_source == "staff_entry"
    end

    def preserved?(check)
      source = check.eligibility_group_source
      source.present? && source != "inferred"
    end

    def current_group(check)
      check.eligibility_group
    end

    def stated?(coverage)
      value = coverage_value(coverage, :eligibility_group)
      !value.nil? && !blank_string?(value)
    end

    def blank_string?(value)
      value.is_a?(String) && value.blank?
    end

    def write_stated!(check, coverage)
      raw = coverage_value(coverage, :eligibility_group)
      group = recognized(raw, AlternateResourceCheck::ELIGIBILITY_GROUPS) || "unknown"
      write!(check, group, stated_source(coverage))
    end

    def stated_source(coverage)
      source = recognized(coverage_value(coverage, :eligibility_group_source), STATED_SOURCES)
      source || "eligibility_response"
    end

    def inferred_group(check, coverage, date_of_service)
      on_date = calendar_date(date_of_service)
      return "unknown" unless on_date

      rules = StateMedicaidRules.lookup(coverage_value(coverage, :state))
      return "unknown" unless rules.configured?

      age = member_age(check, on_date)
      return "unknown" unless age

      classify(rules, age, coverage)
    end

    def classify(rules, age, coverage)
      waiver = waiver_match(rules, coverage)
      return "unknown" if waiver == :undetermined

      adult = adult?(age)
      return waiver_group(adult) if waiver
      return "expansion_adult" if adult && rules.expanded?
      return "other" unless adult

      "unknown"
    end

    def waiver_group(adult)
      adult ? "waiver_adult" : "unknown"
    end

    def adult?(age)
      age.between?(ADULT_MIN_AGE, ADULT_MAX_AGE)
    end

    def waiver_match(rules, coverage)
      rules.waiver_program_for(coverage_value(coverage, :plan_name))
    rescue ArgumentError
      :undetermined
    end

    def member_age(check, on_date)
      dob = calendar_date(patient_for(check)&.dob)
      return unless dob

      age_in_whole_years(dob, on_date)
    end

    def patient_for(check)
      patient_id = check.prc_referral&.case&.patient_identifier
      return if patient_id.blank?

      @adapter.find_patient(patient_id)
    end

    def age_in_whole_years(dob, on_date)
      return if on_date < dob

      years = on_date.year - dob.year
      years -= 1 if on_date < birthday_in_year(dob, on_date.year)
      years
    end

    # Feb 29 is not a calendar day in a non-leap year. Count that
    # birthday on March 1 so the year does not turn on February 28.
    def birthday_in_year(dob, year)
      return Date.new(year, 3, 1) if leap_day?(dob) && !Date.leap?(year)

      Date.new(year, dob.month, dob.day)
    end

    def leap_day?(dob)
      dob.month == 2 && dob.day == 29
    end

    def calendar_date(value)
      case value
      when Date
        Date.new(value.year, value.month, value.day)
      when Time
        value.to_date
      end
    end

    def write!(check, group, source)
      check.update!(
        eligibility_group: group,
        eligibility_group_source: source,
        eligibility_group_set_at: Time.current
      )
      group
    end

    def recognized(value, allowed)
      text = token_text(value)
      text if text && allowed.include?(text)
    end

    def token_text(value)
      case value
      when Symbol
        value.name
      when String
        String.new(value)
      end
    rescue ArgumentError, EncodingError
      nil
    end

    def coverage_value(coverage, key)
      return coverage[key] if coverage.key?(key)

      string_key = key.to_s
      coverage[string_key] if coverage.key?(string_key)
    end
  end
end
