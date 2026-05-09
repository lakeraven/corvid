# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Value object representing a generated demand letter. Carries both
    # the rendered body text (for assertions on legal-citation phrases)
    # and structured fields (so callers and tests can introspect totals,
    # deadlines, FCA-citation flag, installment-offer flag, etc.) without
    # having to re-parse the body.
    DemandLetter = Struct.new(
      :tone,                    # "demand" | "request"
      :legal_basis,             # Array<String>
      :cites_fca,               # bool
      :cites_section_506,       # bool
      :overpayment_amount,      # BigDecimal
      :total_demanded,          # BigDecimal
      :deadline_days,           # Integer
      :return_deadline_date,    # Date
      :authorization_reference, # String | nil
      :referral_terms,          # String | nil
      :claims,                  # Array<Hash>
      :offers_installment,      # bool
      :provider_name,           # String
      :provider_npi,            # String | nil
      :body,                    # String — rendered for free-text assertions
      keyword_init: true
    ) do
      def cites?(phrase)
        body.include?(phrase)
      end
    end
  end
end
