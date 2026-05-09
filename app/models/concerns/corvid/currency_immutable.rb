# frozen_string_literal: true

module Corvid
  # Per ADR 0004: a row's currency_iso is locked at write time. Update
  # attempts that change the value raise ActiveRecord::RecordInvalid
  # rather than being silently dropped — historical records must stay
  # immutable across tenant reconfiguration, and a silent failure mode
  # would let a stale audit re-export quietly disagree with the original.
  module CurrencyImmutable
    extend ActiveSupport::Concern

    included do
      validates :currency_iso, presence: true
      validate :currency_iso_known_to_money
      validate :currency_iso_unchanged_after_persisted
    end

    private

    # Money::Currency.find returns nil for unknown ISO codes; we reject
    # those at the validation layer so an arbitrary 3-char string can't
    # round-trip through monetize and surface only when downstream math
    # tries to subdivide by a missing subunit_to_unit.
    def currency_iso_known_to_money
      return if currency_iso.blank? # presence validator handles this
      return if Money::Currency.find(currency_iso)
      errors.add(:currency_iso, "is not an ISO 4217 currency known to money-rails (got #{currency_iso.inspect})")
    end

    def currency_iso_unchanged_after_persisted
      return unless persisted? && currency_iso_changed?
      errors.add(:currency_iso, "is immutable once a row is persisted")
    end
  end
end
