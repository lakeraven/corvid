# frozen_string_literal: true

require "corvid/adapters/fhir_demo_adapter"
require "corvid/demo/fhir_overlay_data"
require "corvid/demo/cms_rate_seed"
require "corvid/demo/fhir_overlay_ingest"

module Corvid
  module Demo
    # "Corvid overlay via STOCK FHIR" demo (multi-clinic PRC + MLR).
    #
    # A consortium of two synthetic clinics on DIFFERENT source EHRs exports
    # plain FHIR R4. Corvid ingests each via the generic FhirAdapter (no
    # vendor code), runs PRC eligibility, reprices every purchased-care line
    # to its Medicare-Like Rate with the unchanged PrcOverpaymentAnalyzer,
    # and reports per-clinic + consortium "billed -> MLR -> $ recovered."
    #
    # CEHRT-safe: Corvid never becomes the system of record. It reads the
    # certified EHR over stock FHIR and overlays PRC/MLR on top. The same
    # code path works for any FHIR R4 EHR.
    module FhirOverlayDemo
      module_function

      def run(io: $stdout)
        @io = io
        CmsRateSeed.seed!

        per_clinic = FhirOverlayData.clinics.map { |clinic| run_clinic(clinic) }
        print_consortium(per_clinic)
        print_cehrt_note
        { clinics: per_clinic }
      end

      # Ingest + analyze a single clinic inside its own tenant. Returns a
      # hash with the clinic and its analyzer Summary.
      def run_clinic(clinic)
        adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: clinic.resources)
        Corvid.configure { |c| c.adapter = adapter }

        summary = nil
        eligibility = nil
        counts = nil

        Corvid.with_tenant(clinic.tenant) do
          Corvid::TenantContext.current_facility_identifier = clinic.facility
          reset_tenant!(clinic.facility)

          counts = FhirOverlayIngest.ingest(
            facility: clinic.facility,
            patient_identifiers: patient_identifiers(clinic),
            adapter: adapter
          )
          eligibility = run_eligibility_sample(clinic, adapter)
          summary = FhirOverlayIngest.analyze(facility: clinic.facility)
        end

        print_clinic(clinic, counts, eligibility, summary)
        { clinic: clinic, summary: summary, counts: counts, eligibility: eligibility }
      end

      # Drive the EXISTING PRC eligibility path (EligibilityChecklistService)
      # against the stock-FHIR adapter for the clinic's first patient, to show
      # eligibility auto-populates from FHIR (tribal-enrollment extension,
      # identity, residency). Returns the checklist compliance percentage.
      def run_eligibility_sample(clinic, _adapter)
        patient_id = patient_identifiers(clinic).first
        kase = Corvid::Case.find_by(patient_identifier: patient_id, facility_identifier: clinic.facility)
        return nil unless kase

        referral = Corvid::PrcReferral.find_or_create_by!(
          referral_identifier: "rf_overlay_#{clinic.facility}",
          facility_identifier: clinic.facility
        ) { |r| r.case = kase }

        checklist = Corvid::EligibilityChecklistService.populate!(referral)
        { compliance: checklist.compliance_percentage, patient: patient_id }
      rescue StandardError => e
        { error: e.message }
      end

      def reset!(io: $stdout)
        @io = io
        FhirOverlayData.clinics.each do |clinic|
          Corvid.with_tenant(clinic.tenant) do
            reset_tenant!(clinic.facility)
          end
          line "Reset #{clinic.name} (#{clinic.tenant})"
        end
      end

      # --- helpers --------------------------------------------------------

      def reset_tenant!(facility)
        Corvid::PrcOverpaymentAnalysis.unscoped.where(tenant_identifier: current_tenant).delete_all
        Corvid::PrcObligation.for_facility(facility).delete_all
        Corvid::EligibilityChecklist.where(facility_identifier: facility).delete_all
        Corvid::PrcReferral.for_facility(facility).delete_all
        Corvid::Case.for_facility(facility).delete_all
      end

      def current_tenant
        Corvid::TenantContext.current_tenant_identifier
      end

      def patient_identifiers(clinic)
        clinic.resources.select { |r| r["resourceType"] == "Patient" }.map { |r| r["id"] }
      end

      # --- output ---------------------------------------------------------

      def print_clinic(clinic, counts, eligibility, summary)
        banner("#{clinic.name}  (#{clinic.tenant})")
        line "Source EHR:  #{clinic.source_ehr_label}"
        line "Ingest:      stock FHIR R4 via Corvid::Adapters::FhirAdapter (generic, no vendor code)"
        line "Created:     #{counts[:cases_created]} Case(s), #{counts[:obligations_created]} PrcObligation(s)"
        print_skipped(counts)
        if eligibility
          if eligibility[:error]
            line "PRC eligibility: (skipped: #{eligibility[:error]})"
          else
            line "PRC eligibility: checklist #{eligibility[:compliance]}% auto-populated from FHIR (#{eligibility[:patient]})"
          end
        end
        line ""

        # Headline dollars and the per-system breakdown BOTH derive from the
        # clear-priced population, so they cannot disagree, and the % is
        # clear-recovered over clear-paid (a single population), not clear
        # dollars over the whole analyzed paid.
        clear = summary.results.select { |r| r.recovery_confidence == :clear }
        clear_paid = clear.sum { |r| r.paid_amount.to_f }
        clear_recovered = clear.sum { |r| r.overpayment.to_f }

        line "  Claims analyzed:       #{summary.obligations_analyzed}"
        line "  Claims priced (clear): #{summary.by_confidence[:clear].to_i}"
        print_unpriced(summary.by_confidence, summary.obligations_analyzed)
        line "  Billed (=paid, clear): $#{fmt(clear_paid)}"
        line "  Medicare-Like Rate (MLR): $#{fmt(summary.total_medicare_equivalent)}"
        line "  $ RECOVERED (clear):   $#{fmt(summary.total_overpayment_known)}" \
             "  (#{clear_pct(clear_paid, clear_recovered)}% of $ priced clear)"
        line ""
        clear.group_by(&:payment_system).each do |system, results|
          billed = results.sum { |r| r.billed_amount.to_f }
          mlr = results.sum { |r| r.medicare_equivalent.to_f }
          saved = results.sum { |r| r.overpayment.to_f }
          line "    #{system.to_s.upcase.ljust(5)} n=#{results.size}  " \
               "billed=$#{fmt(billed)}  mlr=$#{fmt(mlr)}  recovered=$#{fmt(saved)}"
        end
        line "    confidence: #{summary.by_confidence}"
      end

      def print_consortium(per_clinic)
        summaries = per_clinic.map { |c| c[:summary] }
        claims_analyzed = summaries.sum(&:obligations_analyzed)

        # Aggregate confidence buckets across all clinics.
        by_confidence = summaries.each_with_object(Hash.new(0)) do |s, acc|
          s.by_confidence.each { |bucket, count| acc[bucket] += count }
        end

        # One clear-priced population drives the headline: clear paid, clear
        # MLR, clear recovered, and the % = clear recovered / clear paid.
        clear = summaries.flat_map(&:results).select { |r| r.recovery_confidence == :clear }
        clear_paid = clear.sum { |r| r.paid_amount.to_f }
        clear_mlr = clear.sum { |r| r.medicare_equivalent.to_f }
        clear_recovered = clear.sum { |r| r.overpayment.to_f }

        banner("CONSORTIUM TOTAL (#{per_clinic.size} clinics)")
        per_clinic.each do |c|
          line "  #{c[:clinic].name.ljust(22)} recovered $#{fmt(c[:summary].total_overpayment_known)}"
        end
        line ""
        line "  Claims analyzed:       #{claims_analyzed}"
        line "  Claims priced (clear): #{by_confidence[:clear]}"
        line "  confidence: #{by_confidence.sort_by { |bucket, _| bucket.to_s }.to_h}"
        print_unpriced(by_confidence, claims_analyzed)
        line ""
        line "  Billed (=paid, clear): $#{fmt(clear_paid)}"
        line "  Medicare-Like Rate (MLR, clear): $#{fmt(clear_mlr)}"
        line "  TOTAL $ RECOVERED across the consortium: $#{fmt(clear_recovered)}" \
             "  (#{clear_pct(clear_paid, clear_recovered)}% of $ priced clear)"
      end

      # Print the lines the analyzer could NOT price clear, per bucket, so a
      # non-:clear obligation is never hidden behind an all-clear headline.
      def print_unpriced(by_confidence, total)
        unpriced = by_confidence.reject { |bucket, _| bucket == :clear }
        return if unpriced.empty?

        n = unpriced.values.sum
        detail = unpriced.map { |reason, count| "#{count} #{reason}" }.join(", ")
        line "  #{n} of #{total} lines unpriced: #{detail}"
      end

      # Print claim lines dropped during ingest (missing code / missing or
      # unparseable amount) instead of letting them vanish silently.
      def print_skipped(counts)
        n = counts[:skipped].to_i
        return if n.zero?

        reasons = Array(counts[:skipped_reasons]).map { |s| s[:reason] }.tally
                       .map { |reason, count| "#{count}× #{reason}" }.join(", ")
        line "Skipped:     #{n} line(s): #{reasons}"
      end

      def print_cehrt_note
        banner("CEHRT-SAFE OVERLAY")
        [
          "Corvid ingested every clinic over STOCK FHIR R4 — no vendor-specific",
          "code, no write-back. The certified EHR stays the system of record;",
          "Corvid is a read-only PRC/MLR overlay on top of it. Because ingest is",
          "generic FHIR, the SAME path works for any FHIR R4 EHR in a consortium",
          "regardless of vendor.",
          "",
          "Honesty caveat: the MLR side is real CMS CY2026 data (PFS locality 01,",
          "OPPS national) run through the production PrcOverpaymentAnalyzer, so",
          "results are rate_source: :real / :clear. The billed charges are",
          "synthetic (no real vendor invoice), so the % recovered is a modeled",
          "rate, not one measured from real charges. See docs/demo_fhir_overlay.md."
        ].each { |l| line "  #{l}" }
        line ""
      end

      def banner(title)
        line ""
        line "=" * 78
        line title
        line "=" * 78
      end

      def line(str)
        (@io || $stdout).puts(str)
      end

      # Percent recovered within a SINGLE population: recovered / paid over the
      # same (clear-priced) rows. Avoids dividing clear dollars by all-analyzed
      # paid, which would understate the rate whenever any line is unpriced.
      def clear_pct(paid, recovered)
        return 0 if paid.to_f.zero?

        (recovered / paid * 100).round(1)
      end

      def fmt(n)
        whole, cents = format("%.2f", n.to_f).split(".")
        "#{whole.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse}.#{cents}"
      end
    end
  end
end
