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
    # by the unchanged PrcOverpaymentAnalyzer. A nil find_patient or a nil
    # list_claims is unknown. The call is all-or-nothing: any unknown roster
    # id, or any raise while reading or writing, leaves no Case and no
    # PrcObligation from that call. The call runs in its own savepoint, so
    # that still holds when the caller already has a joinable transaction
    # and rescues the failure. Unknown ids are reported, not ingested as
    # zero claims.
    module FhirOverlayIngest
      module_function

      # Returns { cases_created:, obligations_created:, skipped:,
      # skipped_reasons:, patients_claims_unknown:, patients_unknown: }.
      # skipped_reasons is an Array of { claim:, code:, reason: } for lines that
      # could not be priced (missing code / missing or unparseable amount) —
      # surfaced, not silently dropped. patients_unknown lists roster ids
      # find_patient could not read. patients_claims_unknown lists roster ids
      # whose claims could not be read. Either list being non-empty means
      # nothing from the call was written.
      def ingest(facility:, patient_identifiers:, adapter: Corvid.adapter, imported_at: Time.current)
        ActiveRecord::Base.transaction(requires_new: true) do
          roster = read_roster(patient_identifiers, adapter)
          if roster_unknown?(roster)
            unknown_roster_counts(roster)
          else
            write_roster(facility, roster, imported_at)
          end
        end
      end

      def read_roster(patient_identifiers, adapter)
        patient_identifiers.map { |patient_id| read_roster_row(adapter, patient_id) }
      end

      def read_roster_row(adapter, patient_id)
        patient = adapter.find_patient(patient_id)
        return { patient_id: patient_id, patient: nil, lines: nil } if patient.nil?

        { patient_id: patient_id, patient: patient, lines: adapter.list_claims(patient_id) }
      end

      def roster_unknown?(roster)
        unknown_patient_ids(roster).any? || claims_unknown_ids(roster).any?
      end

      def unknown_patient_ids(roster)
        roster.select { |row| row[:patient].nil? }.map { |row| row[:patient_id] }
      end

      def claims_unknown_ids(roster)
        roster.select { |row| row[:patient] && row[:lines].nil? }.map { |row| row[:patient_id] }
      end

      def unknown_roster_counts(roster)
        empty_ingest_counts.merge(
          patients_claims_unknown: claims_unknown_ids(roster),
          patients_unknown: unknown_patient_ids(roster)
        )
      end

      def empty_ingest_counts
        {
          cases_created: 0,
          obligations_created: 0,
          skipped: 0,
          skipped_reasons: [],
          patients_claims_unknown: [],
          patients_unknown: []
        }
      end

      def write_roster(facility, roster, imported_at)
        skipped = []
        obligations = roster.sum { |row| write_patient(facility, row, imported_at, skipped) }
        empty_ingest_counts.merge(
          cases_created: roster.size,
          obligations_created: obligations,
          skipped: skipped.size,
          skipped_reasons: skipped
        )
      end

      def write_patient(facility, row, imported_at, skipped)
        Corvid::Case.find_or_create_by!(
          patient_identifier: row[:patient].identifier,
          facility_identifier: facility
        )
        write_claim_lines(facility, row[:lines], imported_at, skipped)
      end

      def write_claim_lines(facility, lines, imported_at, skipped)
        lines.count { |line| write_claim_line(facility, line, imported_at, skipped) }
      end

      def write_claim_line(facility, line, imported_at, skipped)
        if (reason = skip_reason(line))
          skipped << { claim: line.claim_identifier, code: line.procedure_code, reason: reason }
          return false
        end

        save_obligation!(facility, line, imported_at)
        true
      end

      def save_obligation!(facility, line, imported_at)
        billed_cents = (line.billed_amount * 100).to_i
        Corvid::PrcObligation.find_or_initialize_by(
          obligation_id: obligation_id_for(line)
        ).tap do |obligation|
          obligation.facility_identifier = facility
          obligation.patient_dfn = line.patient_identifier
          obligation.vendor_id = line.provider_identifier
          obligation.procedure_code = line.procedure_code
          obligation.service_date = line.serviced_date
          obligation.status = "A"
          obligation.billed_amount_cents = billed_cents
          # Pre-repricing baseline: the program pays the full billed
          # charge today (paid = billed). MLR repricing is what recovers
          # the delta — same baseline the GM-6 demo uses.
          obligation.paid_amount_cents = billed_cents
          obligation.currency_iso = line.currency || "USD"
          obligation.fiscal_year = line.serviced_date&.year
          obligation.source_file = "fhir:#{line.claim_identifier}"
          obligation.imported_at = imported_at
          obligation.save!
        end
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
