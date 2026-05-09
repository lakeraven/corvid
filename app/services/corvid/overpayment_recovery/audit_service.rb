# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Audits a batch of paid claims, identifying overpayments where the
    # claim was paid more than the Medicare allowable rate (computed via
    # the existing RepricingService). Output is a per-claim overpayment
    # array plus a per-provider rollup that callers can use to drive
    # demand letter generation.
    module AuditService
      Overpayment = Struct.new(
        :cpt_code, :zip, :paid_amount, :medicare_rate, :overpayment,
        :provider_npi, :provider_name, :date_of_service,
        keyword_init: true
      )

      ProviderRollup = Struct.new(
        :provider_npi, :provider_name, :overpayments, :total_overpayment,
        keyword_init: true
      )

      def self.audit(claims, today: Date.current)
        overpayments = claims.filter_map do |c|
          rate = ::Corvid::RepricingService.reprice(cpt_code: c[:cpt_code], zip: c[:zip], date: today)&.medicare_rate
          next unless rate

          paid = BigDecimal(c[:paid_amount].to_s)
          diff = (paid - rate).round(2)
          next unless diff.positive?

          Overpayment.new(
            cpt_code: c[:cpt_code],
            zip: c[:zip],
            paid_amount: paid,
            medicare_rate: rate,
            overpayment: diff,
            provider_npi: c[:provider_npi],
            provider_name: c[:provider_name],
            date_of_service: c[:date_of_service]
          )
        end

        rollups = overpayments.group_by(&:provider_npi).map do |npi, list|
          ProviderRollup.new(
            provider_npi: npi,
            provider_name: list.first.provider_name,
            overpayments: list,
            total_overpayment: list.sum { |o| o.overpayment }
          )
        end

        { overpayments: overpayments, by_provider: rollups,
          total_overpayment: overpayments.sum { |o| o.overpayment } }
      end
    end
  end
end
