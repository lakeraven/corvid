# frozen_string_literal: true

module Corvid
  # Records the Medicaid eligibility group on a medicaid alternate-resource
  # check. A stated group is kept with its source only when it is exactly
  # expansion_adult, waiver_adult, or other, as a String or a Symbol name.
  # "unknown", nil, blank, wrong case, or an unrecognised value is not a
  # statement; the group is then inferred from state rules and age on the
  # date of service. A waiver plan description is consulted only when the
  # state has work-requirement programs. Ambiguity is recorded as
  # "unknown" — never a guess.
  #
  # The caller is used only for its id. Eligibility fields are
  # snapshotted before an inference is computed, and the adapter runs
  # before any lock. A non-medicaid row, coverage that states a real
  # group, or a fresh unlocked read that already has staff_entry or a
  # stated real group does not call the adapter. Tenant visibility,
  # resource type, and precedence are decided under the lock after
  # reload. A stated real group or a staff entry is never overwritten.
  # A stored "unknown" with a stated source may be replaced by an
  # inference. When the stored inferred group changed during the lookup
  # and disagrees with the new inference, the recorded group is unknown.
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
      coverage = coverage_hash(coverage)
      row = persisted_check(check)
      inferred, snapshot = prepare_inference(row, coverage, date_of_service)
      row.with_lock { apply_locked(row, coverage, inferred, snapshot) }
    end

    def record_staff_entry!(check, eligibility_group:)
      group = required_group(eligibility_group)
      row = persisted_check(check)
      row.with_lock { write_staff!(row, group) }
    end

    private

    def persisted_check(check)
      AlternateResourceCheck.find(check.id)
    end

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

    # The row was just loaded and is not locked. A non-medicaid row, a
    # real group on the coverage, a staff entry, or a stated real group
    # does not need the patient, so a failing lookup cannot block that
    # write. Stored unknown with a stated source still needs one.
    def prepare_inference(row, coverage, date_of_service)
      return unless adapter_needed?(row, coverage)

      snapshot = eligibility_snapshot(row)
      [ inferred_group(row, coverage, date_of_service), snapshot ]
    end

    def adapter_needed?(row, coverage)
      return false unless medicaid?(row)
      return false if stated?(coverage)

      !preserved?(row)
    end

    # with_lock has reloaded this row. Visibility, resource type, and
    # precedence come from that read. An inference was computed, when
    # one was needed, before the lock was taken.
    def apply_locked(row, coverage, inferred, snapshot)
      return unless medicaid?(row)
      return unless referral_visible?(row)
      return current_group(row) if staff_entry?(row)
      return write_stated!(row, coverage) if stated?(coverage)
      return current_group(row) if preserved?(row)

      apply_inference(row, inferred, snapshot)
    end

    def apply_inference(row, inferred, snapshot)
      return current_group(row) if inferred.nil?
      return reconcile_changed_inference(row, inferred) if eligibility_changed?(row, snapshot)

      write!(row, inferred, "inferred")
    end

    # Two inferences that disagree are unknown — never a guess. The
    # same inferred group is left as stored.
    def reconcile_changed_inference(row, inferred)
      return current_group(row) if same_inferred_group?(row, inferred)
      return write!(row, "unknown", "inferred") if inferred_source?(row)

      write!(row, inferred, "inferred")
    end

    def same_inferred_group?(row, inferred)
      inferred_source?(row) && row.eligibility_group == inferred
    end

    def inferred_source?(check)
      check.eligibility_group_source == "inferred"
    end

    def eligibility_changed?(row, snapshot)
      return false if snapshot.nil?

      snapshot != eligibility_snapshot(row)
    end

    def eligibility_snapshot(row)
      [
        row.eligibility_group,
        row.eligibility_group_source,
        row.eligibility_group_set_at
      ]
    end

    def write_staff!(row, group)
      ensure_staff_writable!(row)
      write!(row, group, "staff_entry")
    end

    def staff_entry?(check)
      check.eligibility_group_source == "staff_entry"
    end

    # A staff entry or a stated real group blocks inference. Stored
    # unknown from a stated source does not: inference may replace it.
    def preserved?(check)
      return false if stated_unknown?(check)

      source = check.eligibility_group_source
      source.present? && source != "inferred"
    end

    def stated_unknown?(check)
      check.eligibility_group == "unknown" && STATED_SOURCES.include?(check.eligibility_group_source)
    end

    def current_group(check)
      check.eligibility_group
    end

    # expansion_adult, waiver_adult, or other, as a String or a Symbol
    # name. "unknown", wrong case, blanks, and other types are not a
    # statement.
    def stated?(coverage)
      stated_group(coverage).present?
    end

    def stated_group(coverage)
      group = recognized(coverage_value(coverage, :eligibility_group), AlternateResourceCheck::ELIGIBILITY_GROUPS)
      return if group.nil? || group == "unknown"

      group
    end

    def write_stated!(check, coverage)
      write!(check, stated_group(coverage), stated_source(coverage))
    end

    def stated_source(coverage)
      source = recognized(coverage_value(coverage, :eligibility_group_source), STATED_SOURCES)
      source || "eligibility_response"
    end

    def inferred_group(check, coverage, date_of_service)
      on_date = service_date(date_of_service)
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

    # No programs means no waiver match is possible. Skip the plan
    # description so a missing description is not treated as undetermined.
    def waiver_match(rules, coverage)
      return if rules.work_requirement_programs.empty?

      rules.waiver_program_for(coverage_value(coverage, :plan_name))
    rescue ArgumentError
      :undetermined
    end

    def member_age(check, on_date)
      dob = birth_date(patient_for(check)&.dob)
      return unless dob

      age_in_whole_years(dob, on_date)
    end

    def patient_for(check)
      return unless medicaid?(check)

      patient_id = patient_identifier_for(check)
      return if patient_id.blank?

      @adapter.find_patient(patient_id)
    end

    # The referral is tenant-scoped. No tenant is the same as no patient:
    # do not raise, and do not read a date of birth.
    def patient_identifier_for(check)
      check.prc_referral&.case&.patient_identifier
    rescue Corvid::MissingTenantContextError
      nil
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

    # Time, TimeWithZone, and DateTime keep the calendar date in their
    # own fields. A date of birth is never shifted into Time.zone.
    def birth_date(value)
      case value
      when DateTime, Time, ActiveSupport::TimeWithZone, Date
        Date.new(value.year, value.month, value.day)
      end
    end

    # Time and TimeWithZone are the business date in Time.zone. A
    # DateTime is that same instant. A Date is already a calendar day
    # and is not shifted. DateTime is matched before Date.
    def service_date(value)
      case value
      when DateTime
        value.to_time.in_time_zone(Time.zone).to_date
      when Time, ActiveSupport::TimeWithZone
        value.in_time_zone(Time.zone).to_date
      when Date
        Date.new(value.year, value.month, value.day)
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

    # A missing or nil symbol key falls through to the string key.
    # Any other symbol value, including false and "", is kept.
    def coverage_value(coverage, key)
      if coverage.key?(key)
        value = coverage[key]
        return value unless value.nil?
      end

      coverage[key.to_s]
    end
  end
end
