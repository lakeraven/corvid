# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Whether Section 506 of the Medicare Prescription Drug, Improvement,
    # and Modernization Act of 2003 (codified at 42 CFR 136.30) is the
    # applicable legal basis for an overpayment recovery against a given
    # provider — or whether the recovery has to fall back to contractual
    # terms (referral authorization, voluntary refund, etc).
    #
    # Section 506 only applies when the provider is Medicare-participating
    # AND the customer asserting the recovery is a tribal/IHS PRC program
    # with Section 506 authority.
    module Section506Check
      Result = Struct.new(:applies?, :legal_basis, keyword_init: true) do
        def legal_basis_text
          legal_basis.join("; ")
        end
      end

      SECTION_506_BASIS = [
        "Section 506 MMA 2003 (Medicare Prescription Drug, Improvement, and Modernization Act of 2003)",
        "42 CFR 136.30"
      ].freeze

      CONTRACTUAL_BASIS = [ "contractual" ].freeze

      def self.for_provider(medicare_participating:, customer_has_section_506_authority: true)
        if medicare_participating && customer_has_section_506_authority
          Result.new(applies?: true, legal_basis: SECTION_506_BASIS.dup)
        else
          Result.new(applies?: false, legal_basis: CONTRACTUAL_BASIS.dup)
        end
      end
    end
  end
end
