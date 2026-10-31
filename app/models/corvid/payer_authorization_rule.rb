# frozen_string_literal: true

module Corvid
  # Whether a payer requires authorization for a service code or an
  # inclusive code range. A range's endpoints share one digit-versus-letter
  # pattern, and a code is inside the range only when it shares that
  # pattern too. NULL place of service and NULL plan mean any.
  # Blank text is rejected so it cannot be confused with that wildcard.
  # Stored requirements are only the three decisions; unknown and conflict
  # are lookup outcomes, never rows. Checks mirror the database so
  # insert_all! cannot store a row this model would reject.
  class PayerAuthorizationRule < ::ActiveRecord::Base
    self.table_name = "corvid_payer_authorization_rules"

    include TenantScoped

    REQUIREMENTS = %w[required not_required documentation_only].freeze
    CODE_FORMAT = /\A[A-Z0-9]{5}\z/
    # Same two strings as translate() in the code-pattern CHECK.
    # Digits become 9 and letters become A, position by position.
    CODE_PATTERN_FROM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    CODE_PATTERN_TO = "9999999999AAAAAAAAAAAAAAAAAAAAAAAAAA"

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
    validate :code_range_pattern
    validate :expires_on_on_or_after_effective_on

    # Five ASCII letters or digits, then ASCII upcase. The shape is
    # checked before upcase so Unicode case mapping cannot turn "ı9213"
    # into "I9213" or the ff ligature into "FF123". Nil when the
    # stripped text is not that shape or the encoding is unusable.
    def self.normalize_code(value)
      text = value.to_s.strip
      return unless text.encoding.ascii_compatible? && text.valid_encoding?
      return unless text.match?(/\A[A-Za-z0-9]{5}\z/)

      text.upcase(:ascii)
    rescue ArgumentError, EncodingError
      nil
    end

    def self.code_pattern(code)
      code.tr(CODE_PATTERN_FROM, CODE_PATTERN_TO)
    end

    def self.same_code_pattern?(*codes)
      pattern = code_pattern(codes.first)
      codes.all? { |code| code_pattern(code) == pattern }
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

    # "10000".."6999F" sorts as a range and then covers "2033F". The
    # endpoints have to be the same shape, digit or letter at each spot.
    def code_range_pattern
      return if code_from.blank? || code_to.blank?
      return if self.class.same_code_pattern?(code_from, code_to)

      errors.add(:code_from, "must use the same digit and letter pattern as code_to")
      errors.add(:code_to, "must use the same digit and letter pattern as code_from")
    end

    def expires_on_on_or_after_effective_on
      return if expires_on.blank? || effective_on.blank?
      return if expires_on >= effective_on

      errors.add(:expires_on, "must be on or after effective_on")
    end
  end
end
