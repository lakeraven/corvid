# frozen_string_literal: true

module Corvid
  # Streams a PRC export file into corvid_prc_obligations + corvid_prc_payments,
  # idempotently: re-importing the same file does not duplicate rows; importing
  # a corrected version of an obligation refreshes its fields. Source-file
  # provenance is recorded on every obligation.
  #
  # Reanalysis is a separate operation — `reanalyze` runs PrcOverpaymentAnalyzer
  # over imported obligations and appends a row to corvid_prc_overpayment_analyses
  # without deleting prior history.
  module PrcImporter
    ANALYZER_VERSION = "phase_1.5"

    class << self
      # Import a PRC export. `io_or_string` is whatever PrcReportParser.parse
      # accepts. `source_file` records provenance on each obligation row.
      def import(io_or_string, source_file:)
        report = Corvid::PrcReportParser.parse(io_or_string)
        return empty_result if report.header.nil?

        facility = report.header.facility
        imported_at = Time.current

        ::ActiveRecord::Base.transaction do
          obligation_outcomes = report.obligations.map do |o|
            upsert_obligation(o, facility: facility, source_file: source_file, imported_at: imported_at)
          end

          payment_outcomes = report.payments.map do |p|
            upsert_payment(p)
          end.compact

          {
            obligations_imported: report.obligations.size,
            obligations_inserted: obligation_outcomes.count(:inserted),
            obligations_updated: obligation_outcomes.count(:updated),
            payments_imported: payment_outcomes.size
          }
        end
      end

      # Run PrcOverpaymentAnalyzer over every imported obligation in the
      # tenant; append one corvid_prc_overpayment_analyses row per obligation.
      # Existing analyses are preserved.
      def reanalyze(tenant:)
        analyses_written = 0

        Corvid::TenantContext.with_tenant(tenant) do
          analyzed_at = Time.current

          Corvid::PrcObligation.find_each do |obligation|
            result = analyze_one(obligation)
            next unless result

            Corvid::PrcOverpaymentAnalysis.create!(
              prc_obligation: obligation,
              analyzer_version: ANALYZER_VERSION,
              rate_source_release: nil, # populated when real-data ingestion lands
              payment_system: result.payment_system&.to_s,
              rate_source: result.rate_source&.to_s,
              recovery_confidence: result.recovery_confidence.to_s,
              medicare_equivalent: result.medicare_equivalent,
              overpayment: result.overpayment,
              notes: result.notes,
              analyzed_at: analyzed_at
            )
            analyses_written += 1
          end
        end

        { analyses_written: analyses_written }
      end

      private

      def upsert_obligation(o, facility:, source_file:, imported_at:)
        attrs = {
          facility_identifier: facility,
          patient_dfn: o.patient_dfn,
          vendor_id: o.vendor_id,
          procedure_code: o.procedure_code,
          service_date: o.service_date,
          status: o.status,
          billed_amount: o.billed_amount,
          paid_amount: o.paid_amount,
          savings: o.savings,
          balance: o.balance,
          fiscal_year: o.fiscal_year,
          source_file: source_file,
          imported_at: imported_at
        }

        existing = Corvid::PrcObligation.find_by(obligation_id: o.obligation_id)
        if existing
          existing.update!(attrs)
          :updated
        else
          Corvid::PrcObligation.create!(attrs.merge(obligation_id: o.obligation_id))
          :inserted
        end
      end

      def upsert_payment(p)
        obligation = Corvid::PrcObligation.find_by(obligation_id: p.obligation_id)
        return nil unless obligation

        attrs = {
          prc_obligation: obligation,
          paid_date: p.paid_date,
          check_number: p.check_number,
          amount: p.amount,
          vendor_name: p.vendor_name
        }

        existing = Corvid::PrcPayment.find_by(payment_id: p.payment_id)
        if existing
          existing.update!(attrs)
          existing
        else
          Corvid::PrcPayment.create!(attrs.merge(payment_id: p.payment_id))
        end
      end

      # Analyzer expects an in-memory Report struct; reconstruct one for a
      # single persisted obligation so we can reuse the analyzer logic.
      def analyze_one(obligation)
        header = Corvid::PrcReportParser::Header.new(
          type: nil,
          facility: obligation.facility_identifier,
          export_date: obligation.imported_at&.to_date,
          version: nil
        )
        oblig_struct = Corvid::PrcReportParser::Obligation.new(
          obligation_id: obligation.obligation_id,
          patient_dfn: obligation.patient_dfn,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          service_date: obligation.service_date,
          status: obligation.status,
          billed_amount: obligation.billed_amount,
          paid_amount: obligation.paid_amount,
          savings: obligation.savings,
          balance: obligation.balance,
          fiscal_year: obligation.fiscal_year
        )

        Corvid::PrcOverpaymentAnalyzer.analyze_obligation(oblig_struct, header)
      end

      def empty_result
        {
          obligations_imported: 0, obligations_inserted: 0,
          obligations_updated: 0, payments_imported: 0
        }
      end
    end
  end
end
