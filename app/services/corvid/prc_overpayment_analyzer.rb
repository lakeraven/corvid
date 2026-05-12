# frozen_string_literal: true

module Corvid
  # Analyzes a parsed RPMS PRC report and computes Medicare-Like Rate
  # overpayment per obligation under 42 CFR 136.30. Routes each obligation
  # to the appropriate CMS payment system based on its mapped billing code:
  # PFS for professional services, IPPS DRG for inpatient hospital, OPPS
  # APC for hospital outpatient.
  #
  # Per-payment-system data status:
  #   - PFS uses real ingested CMS data → :clear results.
  #   - IPPS routes through real CMS Final Rule data when loaded for the
  #     (year, DRG, locality) — :clear / :real. When the loaded row's
  #     release_label starts with "stub" (seed canonical CSVs from the
  #     release), or no row is loaded and the in-code IppsStubRateProvider
  #     fills in, results are :stub_estimate / :stub. See
  #     docs/cms_ipps_data.md for coverage status by FY and the
  #     production-ingest workflow.
  #   - OPPS routes through real CMS Final Rule data when loaded for
  #     the (calendar year, APC, locality) — :clear / :real. When the
  #     loaded row's release_label starts with "stub", or no row is
  #     loaded and the in-code OppsStubRateProvider fills in, results
  #     are :stub_estimate / :stub. OPPS uses calendar-year boundaries
  #     (Jan 1), unlike IPPS which uses federal fiscal year.
  #
  # **Screening estimate, not adjudication.** The IPPS pricing formula
  # (`weight × base_rate × wage_index`) is the standard operating
  # payment, intentionally without IME, DSH, capital, outlier, or
  # transfer adjustments. The OPPS formula
  # (`apc_weight × conversion_factor × wage_index`) similarly omits
  # status-indicator packaging, copay/coinsurance, outlier, and
  # device/drug pass-through adjustments. Both are recovery-triage
  # screening estimates — not claim-adjudication amounts. Demand-letter
  # dollar figures should cite the analyzer's source/confidence labels
  # alongside any total.
  #
  # Public contract notes for callers:
  #   - Result#recovery_confidence values: :clear, :stub_estimate,
  #     :unmapped_procedure, :unmapped_facility, :no_rate_for_year
  #   - Result#rate_source values: :real (PFS / IPPS / OPPS with real
  #     CMS data) or :stub (IPPS / OPPS fallback when real data isn't
  #     loaded for the year)
  #   - Summary exposes total_overpayment_known (sum where confidence is
  #     :clear) and total_overpayment_stub_estimate (sum where confidence
  #     is :stub_estimate). total_medicare_equivalent intentionally
  #     sums only :clear results — the stub-derived equivalent dollars
  #     belong to a different statistical population and shouldn't mix
  #     into a single "Medicare-equivalent" figure on a report.
  module PrcOverpaymentAnalyzer
    # Per-obligation result. rate_source_release carries the
    # release_label of the underlying rate row (PFS FeeScheduleEntry,
    # IppsDrgWeight/IppsHospitalRate, OppsApcWeight/OppsConversionFactor)
    # so PrcImporter.reanalyze can persist provenance and the audit
    # packet's methodology.json can attribute each recoverable dollar
    # to a specific CMS release. Nil for in-code stub fallback or
    # exception paths (no source release to attribute).
    Result = Struct.new(
      :obligation_id, :patient_dfn, :vendor_id,
      :procedure_code, :hcpcs, :drg, :apc, :procedure_description,
      :service_date, :facility_zip, :locality,
      :billed_amount, :paid_amount,
      :medicare_equivalent, :overpayment,
      :payment_system, :rate_source, :recovery_confidence,
      :rate_source_release,
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
    #   :clear                  — Medicare equivalent from real CMS data; overpayment is final
    #   :stub_estimate          — Hospital obligation priced via stub provider; rough but actionable
    #   :unmapped_procedure     — Procedure description not in PrcProcedureDictionary
    #   :unmapped_facility      — RPMS facility code not in PrcFacilityDictionary
    #   :no_rate_for_year       — DB has no PFS row for this CPT/locality on the service date
    #   :missing_service_date   — Obligation has no parseable service_date (malformed
    #                             YYYYMMDD upstream); ops must clean the obligation itself,
    #                             distinct from a fee-schedule gap.

    class << self
      def analyze(report)
        results = report.obligations.map { |o| analyze_obligation(o, report.header) }
        summarize(results)
      end

      def analyze_obligation(obligation, header)
        # Short-circuit before procedure/facility lookup: without a
        # service_date, none of the downstream rate paths can do
        # anything sensible. Route this to its own ops-triage reason
        # rather than letting it fall through to :no_rate_for_year,
        # which would mislead ops into looking for missing rate data.
        return missing_service_date(obligation) if obligation.service_date.nil?

        proc_info = Corvid::PrcProcedureDictionary.lookup(obligation.procedure_code)
        facility = Corvid::PrcFacilityDictionary.lookup(header.facility)

        return unmapped_procedure(obligation, facility) unless proc_info
        return unmapped_facility(obligation, proc_info) unless facility

        result = if proc_info.drg
          analyze_inpatient(obligation, proc_info, facility)
        elsif proc_info.apc
          analyze_outpatient(obligation, proc_info, facility)
        else
          analyze_professional(obligation, proc_info, facility)
        end

        apply_cah_adjustment(result)
      end

      private

      # Critical Access Hospitals are paid by Medicare at 101% of reasonable
      # cost. Apply the same 1.01× ceiling at the analyzer boundary when the
      # obligation's vendor is on the CAH registry and the CAH designation
      # was in effect on the service date. The underlying rate row's
      # release_label is preserved so audit-packet provenance is unchanged.
      # Called from analyze_obligation so both the batch path
      # (PrcOverpaymentAnalyzer.analyze) and the per-row importer path
      # (PrcImporter.reanalyze → analyze_obligation) get the adjustment.
      def apply_cah_adjustment(result)
        return result if result.medicare_equivalent.nil?
        return result unless Corvid::CahFacility.applies?(
          vendor_id: result.vendor_id, on: result.service_date
        )

        adjusted = (BigDecimal(result.medicare_equivalent.to_s) * BigDecimal("1.01")).round(2).to_f
        paid = result.paid_amount.to_f
        result.medicare_equivalent = adjusted
        result.overpayment = [ paid - adjusted, 0 ].max.round(2)
        existing = result.notes.to_s
        suffix = " [CAH 1.01× multiplier applied]"
        result.notes = existing.empty? ? suffix.strip : "#{existing}#{suffix}"
        result
      end

      def analyze_professional(obligation, proc_info, facility)
        entry = professional_entry(proc_info.hcpcs, facility.locality, obligation.service_date)

        if entry.nil?
          return Result.new(
            base_fields(obligation, proc_info, facility).merge(
              payment_system: :pfs,
              rate_source: nil, # no rate looked up successfully
              recovery_confidence: :no_rate_for_year,
              notes: "No PFS rate found for CPT #{proc_info.hcpcs} in locality " \
                     "#{facility.locality} on #{obligation.service_date}"
            )
          )
        end

        rate = entry.medicare_rate.to_f.round(2)
        Result.new(
          base_fields(obligation, proc_info, facility).merge(
            medicare_equivalent: rate,
            overpayment: [ obligation.paid_amount.to_f - rate, 0 ].max.round(2),
            payment_system: :pfs,
            rate_source: :real,
            recovery_confidence: :clear,
            rate_source_release: entry.release_label
          )
        )
      end

      def analyze_inpatient(obligation, proc_info, facility)
        # IPPS lookup (#276): real CMS data first; fall back to in-code
        # stub provider when no row is loaded. Recovery confidence keys
        # off the loaded row's release_label — "stub_v1" (or any "stub_*"
        # prefix) marks :stub_estimate so seed canonical CSVs we ship
        # in the release don't get misrepresented as recoverable-now.
        # Real CMS Final Rule labels (e.g., "cms_fy2026_final_rule")
        # mark :clear / :real.
        lookup = Corvid::IppsRateProvider.lookup_for(
          drg_code: proc_info.drg,
          locality: facility.locality,
          date: obligation.service_date
        )

        if lookup
          stub_derived = lookup.release_label.to_s.start_with?("stub")
          Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: lookup.rate,
              overpayment: [ obligation.paid_amount.to_f - lookup.rate, 0 ].max.round(2),
              payment_system: :ipps,
              rate_source: stub_derived ? :stub : :real,
              recovery_confidence: stub_derived ? :stub_estimate : :clear,
              rate_source_release: lookup.release_label,
              notes: stub_derived ?
                "Inpatient hospital claim (DRG #{proc_info.drg}). Priced via " \
                "stub-derived IPPS canonical CSV (release=#{lookup.release_label}); " \
                "replace with real CMS Final Rule data as it's normalized." :
                "Inpatient hospital claim (DRG #{proc_info.drg}). " \
                "Priced via real CMS IPPS Final Rule (release=#{lookup.release_label})."
            )
          )
        else
          stub_rate = Corvid::IppsStubRateProvider.rate_for(
            drg_code: proc_info.drg,
            locality: facility.locality,
            date: obligation.service_date
          )
          Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: stub_rate,
              overpayment: stub_rate ? [ obligation.paid_amount.to_f - stub_rate, 0 ].max.round(2) : nil,
              payment_system: :ipps,
              rate_source: stub_rate ? :stub : nil,
              recovery_confidence: stub_rate ? :stub_estimate : :no_rate_for_year,
              notes: "Inpatient hospital claim (DRG #{proc_info.drg}). Real IPPS " \
                     "rate unavailable for this (year, DRG, locality); using stub " \
                     "national-average estimate."
            )
          )
        end
      end

      # Look up the Medicare professional-component rate for a CPT code,
      # locality, and service date directly via FeeScheduleEntry. Bypasses
      # RepricingService's ZIP-to-locality step because the PRC dictionary
      # already gives us the locality.
      def professional_entry(cpt_code, locality, service_date)
        return nil if cpt_code.nil? || locality.nil? || service_date.nil?

        Corvid::FeeScheduleEntry.rate_for(
          cpt_code: cpt_code,
          locality: locality,
          date: service_date
        )
      end

      def analyze_outpatient(obligation, proc_info, facility)
        # OPPS lookup (#277): real CMS data first; fall back to in-code
        # stub provider when no row is loaded. Mirrors the IPPS analyze_
        # inpatient pattern — release_label drives confidence label.
        lookup = Corvid::OppsRateProvider.lookup_for(
          apc_code: proc_info.apc,
          locality: facility.locality,
          date: obligation.service_date
        )

        if lookup
          stub_derived = lookup.release_label.to_s.start_with?("stub")
          Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: lookup.rate,
              overpayment: [ obligation.paid_amount.to_f - lookup.rate, 0 ].max.round(2),
              payment_system: :opps,
              rate_source: stub_derived ? :stub : :real,
              recovery_confidence: stub_derived ? :stub_estimate : :clear,
              rate_source_release: lookup.release_label,
              notes: stub_derived ?
                "Hospital outpatient (APC #{proc_info.apc}). Priced via " \
                "stub-derived OPPS canonical CSV (release=#{lookup.release_label})." :
                "Hospital outpatient (APC #{proc_info.apc}). " \
                "Priced via real CMS OPPS Final Rule (release=#{lookup.release_label})."
            )
          )
        else
          stub_rate = Corvid::OppsStubRateProvider.rate_for(
            apc_code: proc_info.apc,
            locality: facility.locality,
            date: obligation.service_date
          )
          Result.new(
            base_fields(obligation, proc_info, facility).merge(
              medicare_equivalent: stub_rate,
              overpayment: stub_rate ? [ obligation.paid_amount.to_f - stub_rate, 0 ].max.round(2) : nil,
              payment_system: :opps,
              rate_source: stub_rate ? :stub : nil,
              recovery_confidence: stub_rate ? :stub_estimate : :no_rate_for_year,
              notes: "Hospital outpatient (APC #{proc_info.apc}). Real OPPS " \
                     "rate unavailable for this (year, APC, locality); using " \
                     "stub national-average estimate."
            )
          )
        end
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

      def missing_service_date(obligation)
        Result.new(
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          service_date: nil,
          billed_amount: obligation.billed_amount.to_f,
          paid_amount: obligation.paid_amount.to_f,
          recovery_confidence: :missing_service_date,
          notes: "Obligation has no parseable service_date (upstream date malformed); " \
                 "cannot select a fee schedule. Clean the obligation row, then re-import."
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
