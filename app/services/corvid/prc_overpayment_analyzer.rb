# frozen_string_literal: true

module Corvid
  # Analyzes a parsed RPMS PRC report and computes Medicare-Like Rate
  # overpayment per obligation under 42 CFR 136.30. Routes each obligation
  # to the appropriate CMS payment system based on its mapped billing code:
  # PFS for professional services, IPPS DRG for inpatient hospital, OPPS
  # APC for hospital outpatient.
  #
  # PFS path uses real ingested CMS data and yields :clear results. Hospital
  # obligations (DRG- or APC-mapped) currently route through the IPPS/OPPS
  # stub rate providers and yield :stub_estimate results — directionally
  # correct national-average dollars, replaced by real per-year locality-
  # adjusted rates when #276 (IPPS) and #277 (OPPS) ingestion lands.
  #
  # Public contract notes for callers:
  #   - Result#recovery_confidence values: :clear, :stub_estimate,
  #     :unmapped_procedure, :unmapped_facility, :no_rate_for_year
  #   - Result#rate_source values: :real (PFS) or :stub (IPPS/OPPS Phase 1.5)
  #   - Summary exposes total_overpayment_known (sum where confidence is
  #     :clear) and total_overpayment_stub_estimate (sum where confidence
  #     is :stub_estimate). Reports should label these distinctly.
  module PrcOverpaymentAnalyzer
    # Per-obligation result.
    Result = Struct.new(
      :obligation_id, :patient_dfn, :vendor_id,
      :procedure_code, :hcpcs, :drg, :apc, :procedure_description,
      :service_date, :facility_zip, :locality,
      :billed_amount, :paid_amount,
      :medicare_equivalent, :overpayment,
      :payment_system, :rate_source, :recovery_confidence,
      :notes,
      keyword_init: true
    )

    # Aggregate roll-up returned by `analyze`.
    Summary = Struct.new(
      :obligations_analyzed,
      :total_billed, :total_paid,
      :total_medicare_equivalent, :total_overpayment_known,
      :total_overpayment_stub_estimate,
      :by_confidence,
      :results,
      keyword_init: true
    )

    # Recovery confidence levels.
    #   :clear                — Medicare equivalent from real CMS data; overpayment is final
    #   :stub_estimate        — Hospital obligation priced via stub provider; rough but actionable
    #   :unmapped_procedure   — Procedure description not in PrcProcedureDictionary
    #   :unmapped_facility    — RPMS facility code not in PrcFacilityDictionary
    #   :no_rate_for_year     — DB has no PFS row for this CPT/locality on the service date

    class << self
      def analyze(report)
        results = report.obligations.map { |o| analyze_obligation(o, report.header) }
        summarize(results)
      end

      def analyze_obligation(obligation, header)
        proc_info = Corvid::PrcProcedureDictionary.lookup(obligation.procedure_code)
        facility = Corvid::PrcFacilityDictionary.lookup(header.facility)

        return unmapped_procedure(obligation, facility) unless proc_info
        return unmapped_facility(obligation, proc_info) unless facility

        if proc_info.drg
          analyze_inpatient(obligation, proc_info, facility)
        elsif proc_info.apc
          analyze_outpatient(obligation, proc_info, facility)
        else
          analyze_professional(obligation, proc_info, facility)
        end
      end

      private

      def analyze_professional(obligation, proc_info, facility)
        rate = professional_rate(proc_info.hcpcs, facility.locality, obligation.service_date)

        if rate.nil?
          return Result.new(
            base_fields(obligation, proc_info, facility).merge(
              payment_system: :pfs,
              rate_source: :real,
              recovery_confidence: :no_rate_for_year,
              notes: "No PFS rate found for CPT #{proc_info.hcpcs} in locality " \
                     "#{facility.locality} on #{obligation.service_date}"
            )
          )
        end

        Result.new(
          base_fields(obligation, proc_info, facility).merge(
            medicare_equivalent: rate,
            overpayment: [ obligation.paid_amount.to_f - rate, 0 ].max.round(2),
            payment_system: :pfs,
            rate_source: :real,
            recovery_confidence: :clear
          )
        )
      end

      def analyze_inpatient(obligation, proc_info, facility)
        rate = Corvid::IppsStubRateProvider.rate_for(
          drg_code: proc_info.drg,
          locality: facility.locality,
          date: obligation.service_date
        )

        Result.new(
          base_fields(obligation, proc_info, facility).merge(
            medicare_equivalent: rate,
            overpayment: rate ? [ obligation.paid_amount.to_f - rate, 0 ].max.round(2) : nil,
            payment_system: :ipps,
            rate_source: Corvid::IppsStubRateProvider.source,
            recovery_confidence: :stub_estimate,
            notes: "Inpatient hospital claim (DRG #{proc_info.drg}). Stub IPPS " \
                   "national-average estimate; replace with real CMS rate when " \
                   "#276 (IPPS DRG ingest) lands."
          )
        )
      end

      # Look up the Medicare professional-component rate for a CPT code,
      # locality, and service date directly via FeeScheduleEntry. Bypasses
      # RepricingService's ZIP-to-locality step because the PRC dictionary
      # already gives us the locality.
      def professional_rate(cpt_code, locality, service_date)
        return nil if cpt_code.nil? || locality.nil? || service_date.nil?

        entry = Corvid::FeeScheduleEntry.rate_for(
          cpt_code: cpt_code,
          locality: locality,
          date: service_date
        )
        entry&.medicare_rate&.to_f&.round(2)
      end

      def analyze_outpatient(obligation, proc_info, facility)
        rate = Corvid::OppsStubRateProvider.rate_for(
          apc_code: proc_info.apc,
          locality: facility.locality,
          date: obligation.service_date
        )

        Result.new(
          base_fields(obligation, proc_info, facility).merge(
            medicare_equivalent: rate,
            overpayment: rate ? [ obligation.paid_amount.to_f - rate, 0 ].max.round(2) : nil,
            payment_system: :opps,
            rate_source: Corvid::OppsStubRateProvider.source,
            recovery_confidence: :stub_estimate,
            notes: "Hospital outpatient (APC #{proc_info.apc}). Stub OPPS " \
                   "national-average estimate; replace with real CMS rate when " \
                   "#277 (OPPS APC ingest) lands."
          )
        )
      end

      def unmapped_procedure(obligation, facility)
        Result.new(
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          service_date: obligation.service_date,
          facility_zip: facility&.zip,
          locality: facility&.locality,
          billed_amount: obligation.billed_amount.to_f,
          paid_amount: obligation.paid_amount.to_f,
          recovery_confidence: :unmapped_procedure,
          notes: "Procedure code '#{obligation.procedure_code}' not in PrcProcedureDictionary. " \
                 "Register a mapping to enable repricing."
        )
      end

      def unmapped_facility(obligation, proc_info)
        Result.new(
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          hcpcs: proc_info.hcpcs,
          procedure_description: proc_info.description,
          service_date: obligation.service_date,
          billed_amount: obligation.billed_amount.to_f,
          paid_amount: obligation.paid_amount.to_f,
          recovery_confidence: :unmapped_facility,
          notes: "Facility code not in PrcFacilityDictionary; cannot determine locality."
        )
      end

      def base_fields(obligation, proc_info, facility)
        {
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          hcpcs: proc_info.hcpcs,
          drg: proc_info.drg,
          apc: proc_info.apc,
          procedure_description: proc_info.description,
          service_date: obligation.service_date,
          facility_zip: facility.zip,
          locality: facility.locality,
          billed_amount: obligation.billed_amount.to_f,
          paid_amount: obligation.paid_amount.to_f
        }
      end

      def summarize(results)
        by_confidence = results.group_by(&:recovery_confidence).transform_values(&:size)
        clear = results.select { |r| r.recovery_confidence == :clear }
        stub = results.select { |r| r.recovery_confidence == :stub_estimate }

        Summary.new(
          obligations_analyzed: results.size,
          total_billed: sum(results, :billed_amount),
          total_paid: sum(results, :paid_amount),
          total_medicare_equivalent: sum(clear, :medicare_equivalent),
          total_overpayment_known: sum(clear, :overpayment),
          total_overpayment_stub_estimate: sum(stub, :overpayment),
          by_confidence: by_confidence,
          results: results
        )
      end

      def sum(results, attr)
        results.sum { |r| r.send(attr).to_f }.round(2)
      end
    end
  end
end
