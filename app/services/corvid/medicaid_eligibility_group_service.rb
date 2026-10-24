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
  # The caller is used only for its id. The row is loaded only when its
  # referral is visible in the current tenant, so a missing, hidden, or
  # no-tenant row is never locked. record! returns nil for that row
  # before the adapter, and nil when the row disappears before the lock.
  # The referral id is taken at that load. Eligibility fields are
  # snapshotted before an inference is computed, and the adapter runs
  # before any lock. A non-medicaid row, coverage that states a real
  # group, or a fresh unlocked read that already has staff_entry or a
  # stated real group does not call the adapter. supersede_stated still
  # infers over that stated group when the pinned triple is still
  # stored. A pin that already differs does not call the adapter. The
  # stated fields are replaced only by the later locked write, so a
  # failed inference leaves the previous group in place. Visibility,
  # resource type, and precedence are checked again under the lock. The
  # coverage is for the member of the loaded referral, so a different
  # referral id writes neither a stated nor an inferred group and
  # returns the stored group. A staff entry is never overwritten. A
  # stated real group is kept unless supersede_stated is set. true pins
  # the loaded group, source, and set_at before inference. A hash pins
  # group, source, and set_at from the caller. Under the lock the
  # inference is written only when that pin is unchanged. Any difference
  # leaves the stored group, including a newer stated group. A stored
  # "unknown" with a stated source may be replaced by an inference. When
  # supersede_stated is not set and the stored inferred group changed
  # during the lookup and disagrees with the new inference, the recorded
  # group is unknown.
  #
  # Coverage may state only eligibility_response, state_case_data, or
  # registration. Any other source is recorded as eligibility_response.
  #
  # A stated answer carries as_of, when the source produced it. Only a
  # Time or ActiveSupport::TimeWithZone is known. Anything else,
  # including a String, is unknown and is never taken as the current
  # time. A known time is floored to microseconds before it is compared
  # or stored, which is the precision the column keeps. Under the lock,
  # that answer replaces a stored stated answer when its as_of is equal
  # or newer at that precision. An older known as_of leaves the stored
  # group unwritten. When either time is unknown, the later write wins,
  # the incoming as_of is stored (nil when unknown), and one fixed
  # warning is logged. Inference and staff entry clear as_of.
  #
  # The check's referral must be visible in the current tenant (ADR 0002)
  # or nothing is written. Staff entry raises one ArgumentError that
  # names no identifiers for a missing row, a referral outside this
  # tenant, no tenant, and any resource type in that case, before any
  # lock. It checks visibility again before resource type under the
  # lock. Only a visible row may be rejected as non-medicaid. Age is
  # computed in memory from the adapter patient. The date of birth is
  # never stored, logged, or placed in an error message (ADR 0003).
  class MedicaidEligibilityGroupService
    # Whole years on the date of service. 19 through 64 with no waiver
    # match in an expansion state is expansion_adult. A waiver-program
    # match inside that band is waiver_adult. Outside the band is other,
    # unless a waiver match disagrees, which is unknown.
    ADULT_MIN_AGE = 19
    ADULT_MAX_AGE = 64

    # Adapter coverage cannot claim staff_entry or inferred.
    STATED_SOURCES = %w[eligibility_response state_case_data registration].freeze

    # Logged when a stated answer cannot be ordered against the stored
    # stated answer. Fixed text. No identifiers (ADR 0003).
    UNKNOWN_ANSWER_TIME_WARNING =
      "medicaid eligibility group answer time is unknown; last writer wins"

    # A missing row and a referral outside the current tenant. The text
    # names no identifiers, and it does not depend on resource type.
    NOT_VISIBLE_MESSAGE = "eligibility group cannot be recorded"
    private_constant :NOT_VISIBLE_MESSAGE

    def initialize(adapter:)
      @adapter = adapter
    end

    # supersede_stated lets one locked write replace a stated real group
    # with the inference. true pins the group loaded before inference. A
    # hash pins group, source, and set_at. The locked row must still
    # equal that pin, or the stored group stays. Staff entry is still
    # kept. Inference runs before the lock; if it raises, nothing is
    # written.
    def record!(check, coverage:, date_of_service:, supersede_stated: false)
      coverage = coverage_hash(coverage)
      row = persisted_check(check)
      return unless row

      loaded_referral_id = row.prc_referral_id
      supersede = supersede_snapshot(row, supersede_stated)
      inferred, snapshot = prepare_inference(row, coverage, date_of_service, supersede_stated: supersede)
      row.with_lock do
        apply_locked(row, coverage, inferred, snapshot, loaded_referral_id, supersede_stated: supersede)
      end
    rescue ActiveRecord::RecordNotFound
      # The row can disappear between the unlocked load and the lock.
      # RecordNotFound names the id. Return nil; nothing was written.
      nil
    end

    def record_staff_entry!(check, eligibility_group:)
      group = required_group(eligibility_group)
      row = persisted_check(check)
      raise ArgumentError, NOT_VISIBLE_MESSAGE, cause: nil unless row

      row.with_lock { write_staff!(row, group) }
    rescue ActiveRecord::RecordNotFound
      # The row can disappear between the unlocked load and the lock.
      # RecordNotFound names the id. Raise the same not-visible error
      # instead, with that exception cleared off the cause chain.
      raise ArgumentError, NOT_VISIBLE_MESSAGE, cause: nil
    end

    private

    # Nil unless this check's referral is in the current tenant. A
    # missing row, a hidden referral, and no tenant are nil, so no
    # FOR UPDATE is taken on them.
    def persisted_check(check)
      AlternateResourceCheck.where(
        id: check.id,
        prc_referral_id: Corvid::PrcReferral.select(:id)
      ).first
    rescue Corvid::MissingTenantContextError
      nil
    end

    def medicaid?(check)
      check.resource_type == "medicaid"
    end

    # Re-check visibility before resource type. The referral can change
    # after the unlocked load. A hidden referral is rejected for every
    # resource type with NOT_VISIBLE_MESSAGE, and nothing is written.
    # The medicaid-only message is only for a row visible in this tenant.
    def ensure_staff_writable!(check)
      raise ArgumentError, NOT_VISIBLE_MESSAGE unless referral_visible?(check)
      raise ArgumentError, "eligibility group is only recorded for medicaid" unless medicaid?(check)
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
    # write. supersede_stated still infers over that stated group when
    # the pin still matches. A pin that already differs does not need
    # the patient. Stored unknown with a stated source still needs one.
    def prepare_inference(row, coverage, date_of_service, supersede_stated:)
      return unless adapter_needed?(row, coverage, supersede_stated:)

      snapshot = eligibility_snapshot(row)
      [ inferred_group(row, coverage, date_of_service), snapshot ]
    end

    def adapter_needed?(row, coverage, supersede_stated:)
      return false unless medicaid?(row)
      return false if stated?(coverage)
      return false unless supersede_still_current?(row, supersede_stated)

      !preserved?(row, supersede_stated:)
    end

    # with_lock has reloaded this row. Visibility, resource type, and
    # precedence come from that read. The coverage and any inference
    # belong to the member of the loaded referral id, so a different id
    # writes neither and returns the stored group.
    def apply_locked(row, coverage, inferred, snapshot, loaded_referral_id, supersede_stated:)
      return unless medicaid?(row)
      return unless referral_visible?(row)
      return current_group(row) if staff_entry?(row)
      return current_group(row) if row.prc_referral_id != loaded_referral_id
      return write_stated!(row, coverage) if stated?(coverage)
      return current_group(row) if preserved?(row, supersede_stated:)
      return current_group(row) unless supersede_still_current?(row, supersede_stated)

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

    # true pins the row as loaded, before inference. A hash pins the
    # caller's group, source, and set_at. false does not supersede.
    def supersede_snapshot(row, supersede_stated)
      case supersede_stated
      when true then eligibility_snapshot(row)
      when Hash then stated_supersede_snapshot(supersede_stated)
      else false
      end
    end

    def stated_supersede_snapshot(supersede_stated)
      [
        coverage_value(supersede_stated, :group),
        coverage_value(supersede_stated, :source),
        coverage_value(supersede_stated, :set_at)
      ]
    end

    # No pin means the usual precedence. A pin writes only while the
    # locked group, source, and set_at are still that pin.
    def supersede_still_current?(row, supersede_stated)
      return true unless supersede_stated

      eligibility_snapshot(row) == supersede_stated
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
    # A supersede pin lifts the block for a stated real group only.
    # The pin itself is checked under the lock.
    def preserved?(check, supersede_stated:)
      return false if stated_unknown?(check)
      return false if supersede_stated && STATED_SOURCES.include?(check.eligibility_group_source)

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

    # A stored stated answer with a known as_of is kept when the
    # incoming as_of is known and older. Equal or newer replaces it.
    # An unknown as_of on either side is last-writer-wins, and one
    # fixed warning is logged. The stored time is the incoming time,
    # or nil when that time is unknown.
    def write_stated!(check, coverage)
      incoming = answer_time(coverage_value(coverage, :as_of))
      return current_group(check) if stale_stated_answer?(check, incoming)

      log_unknown_answer_time(check, incoming)
      write!(check, stated_group(coverage), stated_source(coverage), as_of: incoming)
    end

    def stale_stated_answer?(check, incoming)
      stored = stored_stated_answer_time(check)
      stored && incoming && incoming < stored
    end

    def log_unknown_answer_time(check, incoming)
      return unless stored_stated_source?(check)
      return if stored_stated_answer_time(check) && incoming

      Rails.logger.warn(UNKNOWN_ANSWER_TIME_WARNING)
    end

    def stored_stated_answer_time(check)
      return unless stored_stated_source?(check)

      answer_time(check.eligibility_group_as_of)
    end

    def stored_stated_source?(check)
      STATED_SOURCES.include?(check.eligibility_group_source)
    end

    # A String is unknown. It is never parsed, so it cannot become now.
    # A known time is floored to microseconds before the comparison and
    # the store. Ordering is decided at the precision the column keeps.
    def answer_time(value)
      return unless value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      value.floor(6)
    end

    def stated_source(coverage)
      source = recognized(coverage_value(coverage, :eligibility_group_source), STATED_SOURCES)
      source || "eligibility_response"
    end

    def inferred_group(check, coverage, date_of_service)
      on_date = service_date(date_of_service)
      return "unknown" unless on_date

      rules = StateMedicaidRules.lookup(coverage_value(coverage, :state))
      # Read the patient even when the state is not configured. A
      # concurrent write during that lookup has to be visible before
      # an unknown result is stored.
      age = member_age(check, on_date)
      return "unknown" unless rules.configured?
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

    def write!(check, group, source, as_of: nil)
      check.update!(
        eligibility_group: group,
        eligibility_group_source: source,
        eligibility_group_set_at: Time.current,
        eligibility_group_as_of: as_of
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
