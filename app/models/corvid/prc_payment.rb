# frozen_string_literal: true

module Corvid
  # A single payment record from a PRC export's P-record. Multiple payments
  # per obligation are typical (split disbursements across check runs).
  class PrcPayment < ::ActiveRecord::Base
    self.table_name = "corvid_prc_payments"

    include TenantScoped
    include CurrencyImmutable

    monetize :amount_cents, with_model_currency: :currency_iso, allow_nil: true

    belongs_to :prc_obligation, class_name: "Corvid::PrcObligation"

    validates :payment_id, presence: true
  end
end
