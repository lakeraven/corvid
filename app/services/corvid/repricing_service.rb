# Core repricing logic. Pure calculation from public CMS data.
# Open-source candidate — no business logic, no auth, no billing.
module Corvid
  class RepricingService
    Result = Struct.new(
      :cpt_code, :medicare_rate, :locality, :effective_date,
      :work_rvu, :pe_rvu, :mp_rvu, :conversion_factor,
      :work_gpci, :pe_gpci, :mp_gpci,
      :savings, :billed_amount,
      keyword_init: true
    ) do
      def savings_percent
        return 0 unless billed_amount&.positive? && savings&.positive?
        (savings / billed_amount * 100).round(1)
      end
    end

    def self.reprice(cpt_code:, zip:, date: Date.current, billed_amount: nil)
      locality = LocalityLookup.for_zip(zip)
      return nil unless locality

      entry = FeeScheduleEntry.rate_for(cpt_code: cpt_code, locality: locality, date: date)
      return nil unless entry

      rate = entry.medicare_rate

      Result.new(
        cpt_code: cpt_code,
        medicare_rate: rate.round(2),
        locality: locality,
        effective_date: entry.effective_date,
        work_rvu: entry.work_rvu,
        pe_rvu: entry.pe_rvu,
        mp_rvu: entry.mp_rvu,
        conversion_factor: entry.conversion_factor,
        work_gpci: entry.work_gpci,
        pe_gpci: entry.pe_gpci,
        mp_gpci: entry.mp_gpci,
        billed_amount: billed_amount,
        savings: billed_amount ? [(billed_amount - rate).round(2), 0].max : nil
      )
    end

    def self.reprice_batch(claims)
      claims.filter_map do |claim|
        date = claim[:date] || claim[:date_of_service]
        date = date.present? ? Date.parse(date.to_s) : Date.current

        reprice(
          cpt_code: claim[:cpt_code].to_s,
          zip: (claim[:zip] || claim[:facility_zip]).to_s,
          date: date,
          billed_amount: (claim[:billed_amount] || claim[:paid_amount])&.to_f
        )
      end
    end

    def self.audit(claims)
      results = reprice_batch(claims)
      total_billed = results.sum { |r| r.billed_amount || 0 }
      total_medicare = results.sum(&:medicare_rate)
      total_savings = results.sum { |r| r.savings || 0 }

      {
        claims_analyzed: results.length,
        total_billed: total_billed.round(2),
        total_medicare_rate: total_medicare.round(2),
        total_overpayment: total_savings.round(2),
        average_savings_percent: total_billed.positive? ? ((total_savings / total_billed) * 100).round(1) : 0,
        details: results
      }
    end
  end
end
