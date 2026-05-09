# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Generates a DemandLetter from a recovery context (provider info,
    # overpayment claims, customer type, authorization status). Two
    # branches: tribal/Section 506 (citing 42 CFR 136.30 and the FCA,
    # 60-day deadline) vs. non-tribal/contractual (citing the referral
    # authorization terms or requesting a voluntary refund, 30-day
    # deadline, no FCA reference).
    module DemandLetterGenerator
      INSTALLMENT_THRESHOLD = BigDecimal("10000")
      TRIBAL_DEADLINE_DAYS = 60
      RURAL_DEADLINE_DAYS = 30

      def self.generate(
        provider_name:, provider_npi: nil,
        claims:, # Array<Hash> with cpt_code, date_of_service, paid_amount, medicare_rate, overpayment
        customer_type: :tribal, # :tribal | :rural
        medicare_participating: true,
        authorization_reference: nil,
        referral_authorization_terms: nil,
        sent_on: Date.current
      )
        total = claims.sum { |c| BigDecimal(c[:overpayment].to_s) }
        section_506 = customer_type == :tribal && medicare_participating

        if section_506
          tribal_letter(provider_name: provider_name, provider_npi: provider_npi,
                        claims: claims, total: total,
                        authorization_reference: authorization_reference,
                        sent_on: sent_on)
        elsif referral_authorization_terms
          rural_contractual_letter(provider_name: provider_name, claims: claims, total: total,
                                   referral_terms: referral_authorization_terms,
                                   sent_on: sent_on)
        else
          rural_voluntary_letter(provider_name: provider_name, claims: claims, total: total,
                                 sent_on: sent_on)
        end
      end

      def self.tribal_letter(provider_name:, provider_npi:, claims:, total:, authorization_reference:, sent_on:)
        deadline = sent_on + TRIBAL_DEADLINE_DAYS
        offers_installment = total > INSTALLMENT_THRESHOLD
        body = +""
        body << "RECOVERY DEMAND — Section 506 MMA 2003\n\n"
        body << "Pursuant to Section 506 of the Medicare Prescription Drug, Improvement, and Modernization Act of 2003 "
        body << "and 42 CFR 136.30, this letter constitutes a demand for payment in full of overpayments identified "
        body << "in claims paid to #{provider_name}.\n\n"
        body << "Overpayment amount: #{format_money(total)}\n"
        body << "Return deadline: #{deadline.strftime('%Y-%m-%d')} (60 days from this notice).\n"
        body << "Authorization reference: #{authorization_reference}\n" if authorization_reference
        body << "\nClaims:\n"
        claims.each do |c|
          body << "  CPT #{c[:cpt_code]} on #{c[:date_of_service]}: paid #{format_money(c[:paid_amount])}, "
          body << "Medicare allowable #{format_money(c[:medicare_rate])}, overpayment #{format_money(c[:overpayment])}\n"
        end
        body << "\nFalse Claims Act notice: failure to refund within 60 days exposes the provider to liability "
        body << "under the False Claims Act, 31 U.S.C. § 3729, including potential treble damages and per-claim penalties.\n"
        if offers_installment
          body << "\nInstallment plan: amounts over $10,000 may be paid via an installment plan on request.\n"
        end

        DemandLetter.new(
          tone: "demand",
          legal_basis: Section506Check::SECTION_506_BASIS.dup,
          cites_fca: true,
          cites_section_506: true,
          overpayment_amount: total,
          total_demanded: total,
          deadline_days: TRIBAL_DEADLINE_DAYS,
          return_deadline_date: deadline,
          authorization_reference: authorization_reference,
          referral_terms: nil,
          claims: claims,
          offers_installment: offers_installment,
          provider_name: provider_name,
          provider_npi: provider_npi,
          body: body
        )
      end

      def self.rural_contractual_letter(provider_name:, claims:, total:, referral_terms:, sent_on:)
        deadline = sent_on + RURAL_DEADLINE_DAYS
        body = +""
        body << "RECOVERY DEMAND — Contractual Basis\n\n"
        body << "This demand is issued per the terms of the referral authorization, payment is limited to the Medicare allowable rate. "
        body << "The referral authorization specified \"#{referral_terms}\".\n\n"
        body << "Overpayment amount: #{format_money(total)}\n"
        body << "Return deadline: #{deadline.strftime('%Y-%m-%d')} (30 days from this notice).\n"

        DemandLetter.new(
          tone: "demand",
          legal_basis: [ "referral authorization terms" ],
          cites_fca: false,
          cites_section_506: false,
          overpayment_amount: total,
          total_demanded: total,
          deadline_days: RURAL_DEADLINE_DAYS,
          return_deadline_date: deadline,
          authorization_reference: nil,
          referral_terms: referral_terms,
          claims: claims,
          offers_installment: total > INSTALLMENT_THRESHOLD,
          provider_name: provider_name,
          provider_npi: nil,
          body: body
        )
      end

      def self.rural_voluntary_letter(provider_name:, claims:, total:, sent_on:)
        deadline = sent_on + RURAL_DEADLINE_DAYS
        body = +""
        body << "REFUND REQUEST — Voluntary\n\n"
        body << "We respectfully request a voluntary refund. The Medicare allowable rate is the industry standard "
        body << "for comparable claims; payments above that rate appear to exceed customary reimbursement.\n\n"
        body << "Refund amount: #{format_money(total)}\n"
        body << "Suggested return: #{deadline.strftime('%Y-%m-%d')} (30 days).\n"

        DemandLetter.new(
          tone: "request",
          legal_basis: [ "voluntary refund (industry standard / Medicare allowable)" ],
          cites_fca: false,
          cites_section_506: false,
          overpayment_amount: total,
          total_demanded: total,
          deadline_days: RURAL_DEADLINE_DAYS,
          return_deadline_date: deadline,
          authorization_reference: nil,
          referral_terms: nil,
          claims: claims,
          offers_installment: false,
          provider_name: provider_name,
          provider_npi: nil,
          body: body
        )
      end

      def self.format_money(amount)
        BigDecimal(amount.to_s).round(2).to_s("F").then do |s|
          int, frac = s.split(".")
          "$#{int}.#{(frac || '').ljust(2, '0')[0, 2]}"
        end
      end
    end
  end
end
