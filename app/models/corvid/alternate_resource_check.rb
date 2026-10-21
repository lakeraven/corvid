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

    def self.verify_all_for_referral(prc_referral)
      patient_identifier = prc_referral.case&.patient_identifier
      return [] unless patient_identifier

      prc_referral.alternate_resource_checks.map do |check|
        check.verify!
      end
    end

    # An absent determination never counts — PRC is payer of last resort (42 CFR 136.61).
    def self.all_exhausted?(prc_referral)
      checks = prc_referral.alternate_resource_checks
      unavailable_types = checks.unavailable.distinct.pluck(:resource_type)

      (RESOURCE_TYPES - unavailable_types).empty? &&
        checks.where.not(status: UNAVAILABLE_STATUSES).none?
    end

    def self.any_pending?(prc_referral)
      prc_referral.alternate_resource_checks.pending.exists?
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

    def verify!
      patient_identifier = prc_referral.case&.patient_identifier
      return false unless patient_identifier

      result = Corvid.adapter.verify_eligibility(patient_identifier, resource_type)
      # An unreadable answer is not a determination (42 CFR 136.61).
      return false unless result.is_a?(Hash) && (result[:eligible] == true || result[:eligible] == false)

      next_status = status_for_eligibility(result)
      return false if next_status.nil?

      update!(verification_attributes(result, next_status))
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
    # as_of is a Time; a check recorded after that moment is not current.
    # Absence never verifies.
    def current_for?(date_of_service, as_of: Time.current)
      raise ArgumentError, "date_of_service must be a Date" unless date_of_service.instance_of?(Date)
      raise ArgumentError, "as_of must be a Time" unless as_of.is_a?(Time) || as_of.is_a?(ActiveSupport::TimeWithZone)

      fresh_for?(as_of) && coverage_period_covers?(date_of_service) && renewal_current?(date_of_service, as_of)
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

    def verification_attributes(result, next_status)
      {
        status: next_status,
        policy_token: result[:policy_token],
        checked_at: Time.current,
        coverage_start: strict_date(result[:coverage_start]),
        coverage_end: strict_date(result[:coverage_end]),
        renewal_date: strict_date(result[:renewal_date])
      }
    end

    # A Date counts. DateTime is a Date subclass, and Time is not a Date.
    def strict_date(value)
      value.instance_of?(Date) ? value : nil
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

    def coverage_period_covers?(date_of_service)
      return true unless has_coverage?
      return false if coverage_start.nil? || coverage_start > date_of_service

      coverage_end.nil? || coverage_end >= date_of_service
    end

    def renewal_current?(date_of_service, as_of)
      renewal_date.nil? || (renewal_date >= date_of_service && renewal_date >= as_of.to_date)
    end

    # Coordinated sticks only when the adapter's policy token is present
    # and matches the stored token. Any other eligible result is enrolled
    # (verify! stores the new token). Ineligible is not_enrolled. nil
    # leaves the row unchanged — silence is not a determination.
    def status_for_eligibility(result)
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
  end
end
