# frozen_string_literal: true

module Corvid
  class AlternateResourceCheck < ::ActiveRecord::Base
    self.table_name = "corvid_alternate_resource_checks"

    RESOURCE_TYPES = %w[
      medicare_a medicare_b medicare_d medicaid va_benefits
      private_insurance workers_comp auto_insurance liability_coverage
      state_program tribal_program charity_care
    ].freeze

    belongs_to :prc_referral, class_name: "Corvid::PrcReferral"

    enum :status, {
      not_checked: "not_checked",
      checking: "checking",
      enrolled: "enrolled",
      coordinated: "coordinated",
      not_enrolled: "not_enrolled",
      denied: "denied",
      exhausted: "exhausted",
      pending_enrollment: "pending_enrollment"
    }

    validates :resource_type, inclusion: { in: RESOURCE_TYPES }
    validates :resource_type, uniqueness: { scope: :prc_referral_id }

    # ADR 0002: string values, same sets the Postgres CHECKs allow.
    # Not an integer enum. Null on a non-medicaid row; group and source
    # are stored together or not at all, and eligibility_group_set_at is
    # present exactly when the group is present.
    ELIGIBILITY_GROUPS = %w[expansion_adult waiver_adult other unknown].freeze
    ELIGIBILITY_GROUP_SOURCES = %w[
      eligibility_response state_case_data registration staff_entry inferred
    ].freeze

    # A coverage states a group only with one of these. "unknown" is not
    # a statement, and neither is a missing or unrecognised value.
    REAL_STATED_GROUPS = (ELIGIBILITY_GROUPS - %w[unknown]).freeze
    private_constant :REAL_STATED_GROUPS

    # Fixed text only. No patient identifier and no exception text (ADR 0003).
    VERIFY_MEDICAID_ELIGIBILITY_GROUP_WARNING =
      "medicaid eligibility group could not be recorded during verification"

    # Always open, even when placeholder configuration is nil or not an Array.
    PLACEHOLDER_COVERAGE_END = Date.new(9999, 12, 31)
    # Used when placeholder_coverage_end_horizon_years is not a positive Integer.
    PLACEHOLDER_HORIZON_YEARS = 25
    private_constant :PLACEHOLDER_COVERAGE_END, :PLACEHOLDER_HORIZON_YEARS

    # get_coverages returned nil or a non-Array. The source did not answer.
    class UnansweredCoverages < StandardError; end
    private_constant :UnansweredCoverages

    validates :eligibility_group, inclusion: { in: ELIGIBILITY_GROUPS }, allow_nil: true
    validates :eligibility_group_source, inclusion: { in: ELIGIBILITY_GROUP_SOURCES }, allow_nil: true
    validate :eligibility_group_only_on_medicaid
    validate :eligibility_group_paired_with_source
    validate :eligibility_group_set_at_paired_with_group

    RESOURCE_NAMES = {
      "medicare_a" => "Medicare Part A", "medicare_b" => "Medicare Part B",
      "medicare_d" => "Medicare Part D", "medicaid" => "Medicaid",
      "va_benefits" => "VA Benefits", "private_insurance" => "Private Insurance",
      "workers_comp" => "Workers' Compensation", "auto_insurance" => "Auto Insurance",
      "liability_coverage" => "Liability Coverage", "state_program" => "State Program",
      "tribal_program" => "Tribal Program", "charity_care" => "Charity Care"
    }.freeze

    FEDERAL_TYPES = %w[medicare_a medicare_b medicare_d medicaid va_benefits].freeze
    PRIVATE_TYPES = %w[private_insurance workers_comp auto_insurance liability_coverage].freeze

    # Determinations that leave nothing for that payer to pay. `coordinated`
    # is active coverage whose coordination of benefits is already complete,
    # so it counts the same as not enrolled, denied, or exhausted (42 CFR 136.61).
    UNAVAILABLE_STATUSES = %w[not_enrolled denied exhausted coordinated].freeze

    # Coordinated coverage is still active: that payer pays first.
    COVERAGE_STATUSES = %w[enrolled pending_enrollment coordinated].freeze

    scope :active_coverage, -> { where(status: COVERAGE_STATUSES) }
    scope :unavailable, -> { where(status: UNAVAILABLE_STATUSES) }
    scope :pending, -> { where(status: %w[not_checked checking pending_enrollment]) }
    scope :federal, -> { where(resource_type: FEDERAL_TYPES) }
    scope :private_payer, -> { where(resource_type: PRIVATE_TYPES) }

    before_save :set_checked_at, if: :status_changed?

    # Class methods
    def self.create_all_for_referral(prc_referral)
      RESOURCE_TYPES.map do |type|
        prc_referral.alternate_resource_checks.find_or_create_by!(resource_type: type)
      end
    end

    # verify! passes the referral service_date when that column holds a Date.
    def self.verify_all_for_referral(prc_referral)
      patient_identifier = prc_referral.case&.patient_identifier
      return [] unless patient_identifier

      prc_referral.alternate_resource_checks.map do |check|
        check.verify!
      end
    end

    # PRC is payer of last resort (42 CFR 136.61). A row counts only when it
    # is unavailable and current for the date of service. The default date is
    # today — a referral has no service date — so an old or unstamped answer
    # is not a determination.
    def self.all_exhausted?(prc_referral, date_of_service: Date.current, as_of: Time.current)
      by_type = indexed_checks(prc_referral)
      RESOURCE_TYPES.all? { |type| unavailable_for?(by_type[type], date_of_service, as_of) }
    end

    # Without a date, pending is the status scope. With a date, a check that
    # is not current for that date is pending too, including a stale
    # not_enrolled row that could not be re-confirmed.
    def self.any_pending?(prc_referral, date_of_service: nil, as_of: Time.current)
      return prc_referral.alternate_resource_checks.pending.exists? if date_of_service.nil?

      indexed_checks(prc_referral).each_value.any? do |check|
        pending_for?(check, date_of_service, as_of)
      end
    end

    def self.pending_resources(prc_referral)
      prc_referral.alternate_resource_checks.pending.pluck(:resource_type)
    end

    # Seed checks for a new referral from a previous referral's results.
    # Copies status and policy_token only. checked_at stays nil and coverage
    # dates are not copied, so a seeded row is not a current determination
    # (#640) and must be re-verified. Coordination of benefits is per service,
    # so a previous coordinated determination is copied as enrolled.
    def self.seed_from_previous!(new_referral, previous_referral)
      previous_referral.alternate_resource_checks.each do |prev_check|
        new_referral.alternate_resource_checks.find_or_create_by!(resource_type: prev_check.resource_type) do |check|
          check.status = prev_check.coordinated? ? "enrolled" : prev_check.status
          check.checked_at = nil
          check.policy_token = prev_check.policy_token
        end
      end
    end

    # Instance methods

    def exhausted_or_unavailable?
      UNAVAILABLE_STATUSES.include?(status)
    end

    def has_coverage?
      COVERAGE_STATUSES.include?(status)
    end

    def coverage_summary
      case status
      when "not_checked"        then "Not checked"
      when "checking"           then "Checking..."
      when "not_enrolled"       then "Not enrolled"
      when "denied"             then "Denied"
      when "exhausted"          then "Exhausted"
      when "pending_enrollment" then "Pending enrollment"
      when "enrolled"           then resource_name
      else status.to_s.humanize
      end
    end

    # date_of_service is the inquiry date sent to the adapter. It must be
    # nil or an exact Date; anything else raises ArgumentError before the
    # adapter is called, and the message does not include the value. When
    # it is omitted, the referral service_date is sent if that column holds
    # a Date. No other date is invented. When a date was asked, the adapter
    # must echo that exact Date. A missing, nil, or different
    # :date_of_service is not an answer. inquiry_date_of_service stores the
    # asked date. When nothing was asked, it stores the adapter's exact
    # Date, else nil.
    # Per ADR 0005, services inject adapter: and pass it through. Model
    # callers still default to Corvid.adapter; decoupling those paths
    # from the global is #264.
    def verify!(date_of_service: nil, adapter: Corvid.adapter)
      reject_non_date_inquiry!(date_of_service)

      patient_identifier = prc_referral.case&.patient_identifier
      return false unless patient_identifier

      asked = inquiry_date_for_adapter(date_of_service)
      result = eligibility_result(adapter, patient_identifier, asked)
      # An unreadable answer is not a determination (42 CFR 136.61).
      # coverage_start, coverage_end, and renewal_date must be an exact
      # Date or nil. Any other type updates nothing. Absent keys store nil.
      # A present service_active must be true, false, or nil.
      return false unless readable_answer?(result, asked)

      next_status = status_for_eligibility(result)
      return false if next_status.nil?

      update!(verification_attributes(result, next_status, asked))
      record_medicaid_eligibility_group
      true
    end

    # Record that coordination of benefits for this service is done.
    # Only active enrollment can be coordinated. Coordination is not a new
    # eligibility answer, so checked_at stays at the verification time.
    def mark_coordinated!
      raise ArgumentError, "coverage is not active" unless enrolled?

      update!(status: :coordinated)
      true
    end

    def requires_coordination?
      enrolled? && !exhausted?
    end

    def resource_name
      RESOURCE_NAMES[resource_type] || resource_type.to_s.titleize
    end

    def stale?(max_age: 30.days)
      return true if checked_at.nil?
      checked_at < max_age.ago
    end

    # Current for a date of service only when the check is fresh for its
    # resource type and any reported period still covers that date (#640).
    # Month-bounded types (medicaid by default) are current only in the
    # year-month of inquiry_date_of_service (#712). as_of is a Time; a
    # check recorded after that moment is not current. not_enrolled is
    # not current inside its own stored period. Exhausted and denied
    # describe a benefit period: with a stored period they are current
    # only inside it, and with none they are current when fresh.
    # Absence never verifies.
    def current_for?(date_of_service, as_of: Time.current)
      raise ArgumentError, "date_of_service must be a Date" unless date_of_service.instance_of?(Date)
      raise ArgumentError, "as_of must be a Time" unless as_of.is_a?(Time) || as_of.is_a?(ActiveSupport::TimeWithZone)

      fresh_for?(as_of) &&
        inquiry_month_current?(date_of_service) &&
        !negative_inside_coverage?(date_of_service) &&
        coverage_period_covers?(date_of_service) &&
        benefit_period_covers?(date_of_service) &&
        renewal_current?(date_of_service, as_of)
    end

    private

    # checked_at is when eligibility was answered. Only a persisted row
    # leaving not_checked or checking records one. Coordination is not an
    # answer, and a row inserted already answered does not earn a timestamp.
    # status_in_database is the status this save is leaving.
    def set_checked_at
      return unless persisted?
      return unless status_in_database == "not_checked" || status_in_database == "checking"

      self.checked_at = Time.current
    end

    def verification_attributes(result, next_status, asked)
      inquiry = stored_inquiry_date(result, asked)
      {
        status: next_status,
        policy_token: result[:policy_token],
        checked_at: Time.current,
        coverage_start: result[:coverage_start],
        coverage_end: open_ended_date(result[:coverage_end], inquiry),
        renewal_date: open_ended_date(result[:renewal_date], inquiry),
        inquiry_date_of_service: inquiry
      }
    end

    # After the Medicaid answer is saved. record! keeps a staff entry.
    # An EHR failure leaves that answer in place and the group as it was.
    # Nil or a non-Array from get_coverages is that failure, so record!
    # is not called. The pin is read before get_coverages. One matching
    # coverage that states a real group is recorded as that group, and
    # the pin is not passed. No single matching row, or one row that
    # does not state a real group, asks record! to replace the pin.
    # The pin is that group, source, and set_at. A later write changes
    # set_at, so the locked comparison leaves the stored group. A failed
    # inference leaves the previous group. A staff entry stays.
    def record_medicaid_eligibility_group
      return unless resource_type == "medicaid"

      pinned = pinned_stated_group
      coverage = medicaid_group_coverage
      MedicaidEligibilityGroupService.new(adapter: Corvid.adapter).record!(
        self,
        coverage: coverage,
        date_of_service: medicaid_group_date_of_service,
        **stated_group_supersede(coverage, pinned)
      )
    rescue StandardError
      Rails.logger.warn(VERIFY_MEDICAID_ELIGIBILITY_GROUP_WARNING)
    end

    # The sole get_coverages row whose type matches this check.
    # coverage_type when that key is present, otherwise resource_type.
    # None or more than one states nothing.
    def medicaid_group_coverage
      matches = coverages_for_resource_type
      return {} unless matches.one?

      matches.first
    end

    # An Array is an answer, including an empty one. Nil or any other
    # type means the source did not answer.
    def coverages_for_resource_type
      patient_identifier = prc_referral.case&.patient_identifier
      rows = Corvid.adapter.get_coverages(patient_identifier)
      raise UnansweredCoverages unless rows.is_a?(Array)

      rows.select { |row| resource_type_coverage?(row) }
    end

    # Pass the pin read before get_coverages when the answer does not
    # itself state a real group and that pin is a stated group. The
    # service supersedes only while that group, source, and set_at are
    # still stored. Omitting the option leaves record!'s other callers,
    # and a staff entry, on the existing path. The caller reads the row
    # because record! writes through another instance, so this object's
    # attributes can lag the database.
    def stated_group_supersede(coverage, pinned)
      return {} if real_stated_group?(coverage)
      return {} unless pinned

      { supersede_stated: pinned }
    end

    def real_stated_group?(coverage)
      REAL_STATED_GROUPS.include?(group_token(coverage_field(coverage, :eligibility_group)))
    end

    def pinned_stated_group
      group, source, set_at = self.class.where(id: id).pick(
        :eligibility_group,
        :eligibility_group_source,
        :eligibility_group_set_at
      )
      return unless MedicaidEligibilityGroupService::STATED_SOURCES.include?(source)

      { group: group, source: source, set_at: set_at }
    end

    def coverage_field(coverage, key)
      return unless coverage.is_a?(Hash)

      if coverage.key?(key)
        value = coverage[key]
        return value unless value.nil?
      end

      coverage[key.to_s]
    end

    def group_token(value)
      case value
      when Symbol then value.name
      when String then String.new(value)
      end
    rescue ArgumentError, EncodingError
      nil
    end

    def resource_type_coverage?(coverage)
      return false unless coverage.is_a?(Hash)

      coverage_type_value(coverage).to_s.downcase == resource_type
    end

    def coverage_type_value(coverage)
      return coverage[:coverage_type] if coverage.key?(:coverage_type)
      return coverage["coverage_type"] if coverage.key?("coverage_type")
      return coverage[:resource_type] if coverage.key?(:resource_type)

      coverage["resource_type"]
    end

    # Inquiry date, then the referral service date, then the date
    # eligibility was answered. Never Date.current.
    def medicaid_group_date_of_service
      inquiry_date_of_service || referral_service_date || checked_at.to_date
    end

    def referral_service_date
      referral = prc_referral
      return unless referral.has_attribute?(:service_date)

      referral.service_date
    end

    def readable_answer?(result, asked)
      return false unless result.is_a?(Hash)
      return false unless result[:eligible] == true || result[:eligible] == false
      return false unless readable_service_active?(result)
      return false unless readable_inquiry_date?(result, asked)

      readable_coverage_dates?(result)
    end

    # A present value must be exactly true, false, or nil. "false" and 0
    # are not answers.
    def readable_service_active?(result)
      return true unless result.key?(:service_active)

      value = result[:service_active]
      value.nil? || value == true || value == false
    end

    # A date that was asked must come back as that exact Date. Missing,
    # nil, or a different value is not an answer. A present echo that is
    # not an exact Date or nil is not an answer either.
    def readable_inquiry_date?(result, asked)
      echoed = result[:date_of_service]
      return false if result.key?(:date_of_service) && !exact_date_or_nil?(echoed)
      return true unless asked.instance_of?(Date)

      echoed.instance_of?(Date) && echoed == asked
    end

    # The asked date is the echo. With no asked date, store an exact Date
    # from the adapter, else nil, which clears a previous inquiry.
    def stored_inquiry_date(result, asked)
      return asked if asked.instance_of?(Date)

      echoed = result[:date_of_service]
      echoed if echoed.instance_of?(Date)
    end

    # Nil and a missing key are nil. DateTime is a Date subclass and is
    # not an exact Date, so it makes the answer unreadable.
    def readable_coverage_dates?(result)
      %i[coverage_start coverage_end renewal_date].all? { |key| exact_date_or_nil?(result[key]) }
    end

    def exact_date_or_nil?(value)
      value.nil? || value.instance_of?(Date)
    end

    # A non-Date inquiry is rejected before any lookup. nil is omitted.
    def reject_non_date_inquiry!(date_of_service)
      return if date_of_service.nil? || date_of_service.instance_of?(Date)

      raise ArgumentError, "date_of_service must be a Date"
    end

    # The keyword is omitted when the asked date is not a Date, and when
    # the adapter does not declare date_of_service:, so an older adapter
    # still answers. A Date is passed when the adapter accepts it. An
    # answer that does not echo an asked date is still unreadable.
    def eligibility_result(adapter, patient_identifier, inquiry)
      if pass_inquiry_date?(adapter, inquiry)
        adapter.verify_eligibility(patient_identifier, resource_type, date_of_service: inquiry)
      else
        adapter.verify_eligibility(patient_identifier, resource_type)
      end
    end

    def pass_inquiry_date?(adapter, inquiry)
      inquiry.instance_of?(Date) && adapter_accepts_inquiry_date?(adapter)
    end

    def adapter_accepts_inquiry_date?(adapter)
      adapter.method(:verify_eligibility).parameters.any? { |type, name|
        type == :keyrest || (name == :date_of_service && (type == :key || type == :keyreq))
      }
    end

    # Caller date wins. Otherwise the referral service_date when that
    # column holds a Date.
    def inquiry_date_for_adapter(date_of_service)
      return date_of_service unless date_of_service.nil?

      service_date = referral_service_date
      service_date if service_date.instance_of?(Date)
    end

    # Sentinel dates and dates past the horizon are open coverage (nil).
    def open_ended_date(date, inquiry_date)
      return nil if date.nil?
      return nil if placeholder_coverage_end?(date)
      return nil if beyond_placeholder_horizon?(date, inquiry_date)

      date
    end

    def placeholder_coverage_end?(date)
      return true if date == PLACEHOLDER_COVERAGE_END

      configured_placeholder_date?(date)
    end

    # Only an Array adds dates. Exact Dates count. A String counts when
    # Date.iso8601 parses it. Anything else is ignored and does not raise.
    def configured_placeholder_date?(date)
      dates = Corvid.configuration.placeholder_coverage_end_dates
      return false unless dates.is_a?(Array)

      dates.any? { |element| placeholder_list_date(element) == date }
    end

    def placeholder_list_date(element)
      return element if element.instance_of?(Date)
      return unless element.instance_of?(String)

      parsed = Date.iso8601(element)
      parsed if parsed.instance_of?(Date)
    rescue ArgumentError
      nil
    end

    # Strictly past the horizon. With no inquiry date, measure from the
    # answer time in the host zone.
    def beyond_placeholder_horizon?(date, inquiry_date)
      anchor = inquiry_date.instance_of?(Date) ? inquiry_date : Time.current.to_date
      date > anchor + placeholder_horizon_years.years
    end

    def placeholder_horizon_years
      years = Corvid.configuration.placeholder_coverage_end_horizon_years
      return years if years.is_a?(Integer) && years.positive?

      PLACEHOLDER_HORIZON_YEARS
    end

    # Month-bounded checks are current only in the inquiry year-month.
    # A missing inquiry date is not current, saved or not. The reader
    # raises when a partial load omitted the column.
    def inquiry_month_current?(date_of_service)
      return true unless month_bounded_type?

      inquiry = inquiry_date_of_service
      return false if inquiry.nil?

      inquiry.year == date_of_service.year && inquiry.month == date_of_service.month
    end

    # Medicaid is always month-bounded. Configured names are added and
    # compared case-insensitively. Nil or a non-Array adds nothing.
    def month_bounded_type?
      medicaid_resource? || configured_month_bounded_type?
    end

    def medicaid_resource?
      resource_type.to_s.downcase == "medicaid"
    end

    def configured_month_bounded_type?
      types = Corvid.configuration.month_bounded_eligibility_resource_types
      return false unless types.is_a?(Array)

      name = resource_type.to_s.downcase
      types.any? { |type| type.to_s.downcase == name }
    end

    # A checked_at later than as_of is a future answer, not a current one.
    def fresh_for?(as_of)
      return false if not_checked? || checking? || checked_at.nil?
      return false if checked_at > as_of

      checked_at >= as_of - configured_max_age
    end

    def configured_max_age
      Corvid.configuration.alternate_resource_check_max_age.fetch(resource_type)
    end

    # Only not_enrolled is not current inside its own stored period.
    def negative_inside_coverage?(date_of_service)
      return false unless not_enrolled?

      partial_period_covers?(date_of_service)
    end

    # An exhausted or denied answer is about the benefit period it reports.
    # A 2026 exhausted period says nothing about a 2027 date of service.
    # With no stored period the fresh answer stands.
    def benefit_period_covers?(date_of_service)
      return true unless exhausted? || denied?
      return true if coverage_start.nil? && coverage_end.nil?

      partial_period_covers?(date_of_service)
    end

    # A stored period covers the date of service when at least one bound
    # is present, coverage_start is nil or on or before that date, and
    # coverage_end is nil or on or after it.
    def partial_period_covers?(date_of_service)
      return false if coverage_start.nil? && coverage_end.nil?

      (coverage_start.nil? || coverage_start <= date_of_service) &&
        (coverage_end.nil? || coverage_end >= date_of_service)
    end

    def coverage_period_covers?(date_of_service)
      return true unless has_coverage?

      stored_period_covers?(date_of_service)
    end

    # coverage_start <= date of service, and coverage_end is nil or >= it.
    def stored_period_covers?(date_of_service)
      return false if coverage_start.nil? || coverage_start > date_of_service

      coverage_end.nil? || coverage_end >= date_of_service
    end

    # renewal_date, when present, must be on or after the date of service
    # and on or after as_of.in_time_zone.to_date.
    def renewal_current?(date_of_service, as_of)
      return true if renewal_date.nil?

      renewal_date >= date_of_service && renewal_date >= as_of.in_time_zone.to_date
    end

    # Coordinated sticks only when the adapter's policy token is present
    # and matches the stored token. Any other eligible result is enrolled
    # (verify! stores the new token). Ineligible is not_enrolled.
    # service_active false is not enrolled even when the plan dates cover
    # the inquiry. nil leaves the row unchanged — silence is not a
    # determination.
    def status_for_eligibility(result)
      return :not_enrolled if result[:service_active] == false

      case result[:eligible]
      when true then eligible_status(result)
      when false then :not_enrolled
      end
    end

    def eligible_status(result)
      return :coordinated if same_coordinated_policy?(result[:policy_token])

      :enrolled
    end

    def same_coordinated_policy?(token)
      coordinated? && token.present? && token == policy_token
    end

    def eligibility_group_only_on_medicaid
      return if eligibility_group.nil? || resource_type == "medicaid"

      errors.add(:eligibility_group, "is only recorded for medicaid")
    end

    def eligibility_group_paired_with_source
      return if eligibility_group.nil? == eligibility_group_source.nil?

      if eligibility_group.nil?
        errors.add(:eligibility_group, "must be set when eligibility_group_source is set")
      else
        errors.add(:eligibility_group_source, "must be set when eligibility_group is set")
      end
    end

    def eligibility_group_set_at_paired_with_group
      return if eligibility_group.nil? == eligibility_group_set_at.nil?

      errors.add(:eligibility_group_set_at, "must be present exactly when eligibility group is present")
    end

    class << self
      private

      def indexed_checks(prc_referral)
        prc_referral.alternate_resource_checks.reload.index_by(&:resource_type)
      end

      # current_for? is the only freshness test: the configured per-type
      # max age and the coverage period.
      def unavailable_for?(check, date_of_service, as_of)
        return false unless check&.exhausted_or_unavailable?

        check.current_for?(date_of_service, as_of: as_of)
      end

      def pending_for?(check, date_of_service, as_of)
        return true if check.not_checked? || check.checking? || check.pending_enrollment?

        !check.current_for?(date_of_service, as_of: as_of)
      end
    end
  end
end
