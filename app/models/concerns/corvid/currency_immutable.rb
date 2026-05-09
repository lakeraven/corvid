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
      validate :currency_iso_unchanged_after_persisted
    end

    private

    def currency_iso_unchanged_after_persisted
      return unless persisted? && currency_iso_changed?
      errors.add(:currency_iso, "is immutable once a row is persisted")
    end
  end
end
