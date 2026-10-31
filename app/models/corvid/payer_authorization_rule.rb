# frozen_string_literal: true

module Corvid
  # Whether a payer requires authorization for a service code or an
  # inclusive code range. NULL place of service and NULL plan mean any.
  # Blank text is rejected so it cannot be confused with that wildcard.
  # Stored requirements are only the three decisions; unknown and conflict
  # are lookup outcomes, never rows. Checks mirror the database so
  # insert_all! cannot store a row this model would reject.
  class PayerAuthorizationRule < ::ActiveRecord::Base
    self.table_name = "corvid_payer_authorization_rules"

    include TenantScoped

    REQUIREMENTS = %w[required not_required documentation_only].freeze
    CODE_FORMAT = /\A[A-Z0-9]{5}\z/

    validates :payer_identifier, presence: true
    validates :requirement, inclusion: { in: REQUIREMENTS }
    validates :effective_on, presence: true
    validates :place_of_service, presence: true, allow_nil: true
    validates :plan_identifier, presence: true, allow_nil: true
    validates :service_code, format: { with: CODE_FORMAT }, allow_nil: true
    validates :code_from, format: { with: CODE_FORMAT }, allow_nil: true
    validates :code_to, format: { with: CODE_FORMAT }, allow_nil: true

    validate :exactly_one_code_form
    validate :code_range_bounds
    validate :expires_on_on_or_after_effective_on

    # insert_all! is implemented as `all.insert_all!`. `all` runs the tenant
    # default scope, which raises with no thread tenant and then overwrites
    # tenant_identifier from that scope. These rows already name their tenant.
    def self.insert_all!(...)
      unscoped.insert_all!(...)
    end

    def self.insert_all(...)
      unscoped.insert_all(...)
    end

    private

    # One target per row. An exact code and a range together would match
    # the same service twice and manufacture a conflict.
    def exactly_one_code_form
      exact = service_code.present?
      complete = code_from.present? && code_to.present?
      ranged = code_from.present? || code_to.present?
      return if exact && !ranged
      return if !exact && complete

      errors.add(:base, "exactly one of service_code or a code range")
      errors.add(:service_code, "is invalid")
    end

    def code_range_bounds
      return if code_from.blank? || code_to.blank?
      return if code_from.length == code_to.length && code_from <= code_to

      errors.add(:code_from, "must be the same length as code_to and not after it")
      errors.add(:code_to, "must be on or after code_from")
    end

    def expires_on_on_or_after_effective_on
      return if expires_on.blank? || effective_on.blank?
      return if expires_on >= effective_on

      errors.add(:expires_on, "must be on or after effective_on")
    end
  end
end
