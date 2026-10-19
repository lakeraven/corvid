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
    # Copies status and checked_at — stale checks will need re-verification.
    # Coordination of benefits is per service, so a previous coordinated
    # determination is copied as enrolled and must be coordinated again.
    def self.seed_from_previous!(new_referral, previous_referral)
      previous_referral.alternate_resource_checks.each do |prev_check|
        new_referral.alternate_resource_checks.find_or_create_by!(resource_type: prev_check.resource_type) do |check|
          check.status = prev_check.coordinated? ? "enrolled" : prev_check.status
          check.checked_at = prev_check.checked_at
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

      update!(
        status: next_status,
        policy_token: result[:policy_token],
        checked_at: Time.current
      )
      true
    end

    # Record that coordination of benefits for this service is done.
    # Only active enrollment can be coordinated.
    def mark_coordinated!
      raise ArgumentError, "coverage is not active" unless enrolled?

      update!(status: :coordinated, checked_at: Time.current)
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

    private

    def set_checked_at
      self.checked_at = Time.current if status_previously_was == "not_checked" || status_previously_was == "checking"
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
