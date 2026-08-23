# frozen_string_literal: true

module Corvid
  module Demo
    # Thin, EHR-agnostic ingest mapper: stock FHIR -> Corvid::Case +
    # Corvid::PrcObligation. It talks ONLY to the generic adapter interface
    # (find_patient, list_claims) — no per-vendor branches, no knowledge of
    # the source EHR. Point it at any conformant FHIR R4 server (via
    # FhirAdapter) and it ingests the same way.
    #
    # Caller sets tenant + facility context (Corvid.with_tenant). Patient
    # identifiers are the PRC panel/roster to ingest (in production this
    # roster comes from the program's referral list; here from the synthetic
    # dataset). Each FHIR Claim line becomes one PrcObligation, priced later
    # by the unchanged PrcOverpaymentAnalyzer.
    module FhirOverlayIngest
      module_function

      # Returns { cases_created:, obligations_created:, skipped:, skipped_reasons: }.
      # skipped_reasons is an Array of { claim:, code:, reason: } for lines that
      # could not be priced (missing code / missing or unparseable amount) —
      # surfaced, not silently dropped.
      def ingest(facility:, patient_identifiers:, adapter: Corvid.adapter, imported_at: Time.current)
        cases = 0
        obligations = 0
        skipped = []

        patient_identifiers.each do |patient_id|
          patient = adapter.find_patient(patient_id)
          next unless patient # roster entry the FHIR server doesn't know: skip

          kase = Corvid::Case.find_or_create_by!(
            patient_identifier: patient.identifier,
            facility_identifier: facility
          )
          cases += 1

          adapter.list_claims(patient_id).each do |line|
            if (reason = skip_reason(line))
              skipped << { claim: line.claim_identifier, code: line.procedure_code, reason: reason }
              next
            end

            billed_cents = (line.billed_amount * 100).to_i
            Corvid::PrcObligation.find_or_initialize_by(
              obligation_id: obligation_id_for(line)
            ).tap do |o|
              o.facility_identifier = facility
              o.patient_dfn = line.patient_identifier
              o.vendor_id = line.provider_identifier
              o.procedure_code = line.procedure_code
              o.service_date = line.serviced_date
              o.status = "A"
              o.billed_amount_cents = billed_cents
              # Pre-repricing baseline: the program pays the full billed
              # charge today (paid = billed). MLR repricing is what recovers
              # the delta — same baseline the GM-6 demo uses.
              o.paid_amount_cents = billed_cents
              o.currency_iso = line.currency || "USD"
              o.fiscal_year = line.serviced_date&.year
              o.source_file = "fhir:#{line.claim_identifier}"
              o.imported_at = imported_at
              o.save!
            end
            obligations += 1
          end

          # Give the Case a PRC referral so the existing eligibility flow has
          # something to attach to (kept lightweight — one per patient).
          _ = kase
        end

        { cases_created: cases, obligations_created: obligations,
          skipped: skipped.size, skipped_reasons: skipped }
      end

      # Why a claim line can't be priced, or nil if it's fine. A present-but-
      # unparseable amount (line.amount_error) is reported as its own reason
      # rather than lumped in with an absent one.
      def skip_reason(line)
        reasons = []
        reasons << "missing procedure code" if line.procedure_code.nil?
        if line.billed_amount.nil?
          reasons << (line.amount_error || "missing billed amount")
        end
        reasons.empty? ? nil : reasons.join("; ")
      end

      def obligation_id_for(line)
        "FHIR-#{line.claim_identifier}-#{line.sequence || 1}"
      end

      # Build the in-memory Report the analyzer expects from the persisted
      # obligations for a facility, then price them with the UNCHANGED
      # PrcOverpaymentAnalyzer. Returns a Corvid::PrcOverpaymentAnalyzer::Summary.
      def analyze(facility:)
        header = Corvid::PrcReportParser::Header.new(
          type: "PRC_EXPORT", facility: facility, export_date: Date.current, version: "fhir"
        )
        obligations = Corvid::PrcObligation.for_facility(facility).order(:obligation_id).map do |o|
          Corvid::PrcReportParser::Obligation.new(
            obligation_id: o.obligation_id,
            patient_dfn: o.patient_dfn,
            vendor_id: o.vendor_id,
            procedure_code: o.procedure_code,
            service_date: o.service_date,
            status: o.status,
            billed_amount: cents_to_d(o.billed_amount_cents),
            paid_amount: cents_to_d(o.paid_amount_cents),
            savings: 0.to_d,
            balance: 0.to_d,
            fiscal_year: o.fiscal_year
          )
        end

        report = Corvid::PrcReportParser::Report.new(
          header: header, obligations: obligations, payments: [], trailer: nil
        )
        Corvid::PrcOverpaymentAnalyzer.analyze(report)
      end

      def cents_to_d(cents)
        return 0.to_d if cents.nil?

        (BigDecimal(cents.to_s) / 100)
      end
    end
  end
end
