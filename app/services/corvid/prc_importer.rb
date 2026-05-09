# frozen_string_literal: true

module Corvid
  # Imports a PRC export file into corvid_prc_obligations + corvid_prc_payments,
  # idempotently: re-importing the same file does not duplicate rows; importing
  # a corrected version of an obligation refreshes its fields and reconciles
  # its payments (rows missing from the new export are deleted, so reversed
  # or removed payments don't drift from RPMS as source-of-truth).
  # Source-file provenance is recorded on every obligation.
  #
  # Reanalysis is a separate operation — `reanalyze` runs PrcOverpaymentAnalyzer
  # over imported obligations and appends a row to corvid_prc_overpayment_analyses
  # without deleting prior history.
  #
  # `import` raises MalformedExportError when the parsed file has no header,
  # so a wrong file type, truncated upload, or parser drift surfaces as a
  # noisy failure rather than a silent zero-row "success." Payments whose
  # obligation isn't in the same export are dropped, counted, and logged
  # (under the same "complete restatement" semantic as reconciliation).
  module PrcImporter
    ANALYZER_VERSION = "phase_1.5"

    class MalformedExportError < StandardError; end

    class << self
      # Import a PRC export. `io_or_string` is whatever PrcReportParser.parse
      # accepts. `source_file` records provenance on each obligation row.
      def import(io_or_string, source_file:)
        report = Corvid::PrcReportParser.parse(io_or_string)
        raise MalformedExportError, "PRC export missing header (source: #{source_file})" if report.header.nil?

        tenant = Corvid::TenantContext.current_tenant_identifier
        raise Corvid::MissingTenantContextError, "current_tenant_identifier not set" unless tenant

        facility = report.header.facility
        imported_at = Time.current

        ::ActiveRecord::Base.transaction do
          obligation_counts = upsert_obligations(
            report.obligations,
            tenant: tenant, facility: facility,
            source_file: source_file, imported_at: imported_at
          )

          oblig_pks_in_file = obligation_pks_for(report.obligations.map(&:obligation_id))
          payment_counts = reconcile_and_upsert_payments(
            report.payments,
            tenant: tenant,
            oblig_pks_in_file: oblig_pks_in_file,
            source_file: source_file
          )

          {
            obligations_imported: report.obligations.size,
            obligations_inserted: obligation_counts[:inserted],
            obligations_updated: obligation_counts[:updated],
            payments_parsed: report.payments.size,
            payments_imported: payment_counts[:imported],
            payments_dropped_orphan: payment_counts[:dropped_orphan]
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

      # Bulk-upsert obligations in a single round trip. Dedupes within the
      # file by obligation_id (last record wins) and pre-queries existing
      # ids so we can report inserted vs updated (upsert_all returns no
      # per-row outcomes). When file count exceeds inserted + updated,
      # the gap is in-file duplicates — visible directly in the result.
      def upsert_obligations(obligations, tenant:, facility:, source_file:, imported_at:)
        return { inserted: 0, updated: 0 } if obligations.empty?

        unique_obligations = obligations.uniq { |o| o.obligation_id }
        ids = unique_obligations.map(&:obligation_id)
        existing_ids = Corvid::PrcObligation.where(obligation_id: ids).pluck(:obligation_id).to_set

        rows = unique_obligations.map do |o|
          {
            tenant_identifier: tenant,
            facility_identifier: facility,
            obligation_id: o.obligation_id,
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
        end

        Corvid::PrcObligation.upsert_all(
          rows,
          unique_by: :idx_corvid_prc_obligations_tenant_oblig
        )

        inserted = ids.count { |id| !existing_ids.include?(id) }
        { inserted: inserted, updated: ids.size - inserted }
      end

      # Reconcile payments per obligation, then bulk-upsert. Reconciliation
      # treats every obligation in this file as a complete restatement of
      # its payments — rows with payment_ids not in the file are deleted,
      # and obligations listed with zero payments have all their payments
      # dropped. Payments whose obligation isn't in this same file are
      # treated as orphans (parser drift / truncated upload signal),
      # dropped, counted, and logged.
      def reconcile_and_upsert_payments(payments, tenant:, oblig_pks_in_file:, source_file:)
        unique_payments = payments.uniq { |p| p.payment_id }

        rows = []
        dropped_orphan = 0
        payment_ids_by_oblig_pk = Hash.new { |h, k| h[k] = [] }

        unique_payments.each do |p|
          oblig_pk = oblig_pks_in_file[p.obligation_id]
          unless oblig_pk
            dropped_orphan += 1
            next
          end

          rows << {
            tenant_identifier: tenant,
            prc_obligation_id: oblig_pk,
            payment_id: p.payment_id,
            paid_date: p.paid_date,
            check_number: p.check_number,
            amount: p.amount,
            vendor_name: p.vendor_name
          }
          payment_ids_by_oblig_pk[oblig_pk] << p.payment_id
        end

        if dropped_orphan.positive?
          Rails.logger.warn(
            "[PrcImporter] dropped #{dropped_orphan} orphan payment(s) " \
            "(obligation not in same export) source=#{source_file}"
          )
        end

        oblig_pks_in_file.each_value do |oblig_pk|
          pmt_ids_in_file = payment_ids_by_oblig_pk[oblig_pk]
          scope = Corvid::PrcPayment.where(prc_obligation_id: oblig_pk)
          scope = scope.where.not(payment_id: pmt_ids_in_file) if pmt_ids_in_file.any?
          scope.delete_all
        end

        if rows.any?
          Corvid::PrcPayment.upsert_all(
            rows,
            unique_by: :idx_corvid_prc_payments_tenant_pmt
          )
        end

        { imported: rows.size, dropped_orphan: dropped_orphan }
      end

      def obligation_pks_for(obligation_external_ids)
        return {} if obligation_external_ids.empty?

        Corvid::PrcObligation
          .where(obligation_id: obligation_external_ids)
          .pluck(:obligation_id, :id)
          .to_h
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
    end
  end
end
