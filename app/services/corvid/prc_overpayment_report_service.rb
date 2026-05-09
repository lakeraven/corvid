# frozen_string_literal: true

require "csv"
require "json"

module Corvid
  # Generates audit-ready overpayment reports from persisted analysis rows.
  # Three output shapes — Hash (summary/detail), CSV, JSON — all built from
  # each obligation's most recent PrcOverpaymentAnalysis so a re-analysis
  # at a higher confidence supersedes earlier estimates without losing
  # history (the analyses table keeps prior rows for audit).
  #
  # Every detail row carries the provenance fields auditors and recovery
  # counterparties need to answer "where does this number come from?":
  # analyzer_version, rate_source, rate_source_release, source_file.
  #
  # Recoverable-now overpayments (recovery_confidence = "clear") are
  # reported separately from stub-estimate ("stub_estimate") so a tribal
  # council never confuses directional dollars with collectable dollars.
  module PrcOverpaymentReportService
    SUMMARY_CSV_HEADERS = %w[
      fiscal_year vendor_id payment_system
      obligations_count
      total_billed total_paid total_medicare_equivalent
      total_overpayment_known total_overpayment_stub_estimate
    ].freeze

    DETAIL_CSV_HEADERS = %w[
      obligation_id fiscal_year service_date vendor_id procedure_code
      payment_system recovery_confidence
      billed_amount paid_amount medicare_equivalent overpayment
      analyzer_version rate_source rate_source_release
      source_file analyzed_at
    ].freeze

    class << self
      # Aggregate totals across the filtered analysis set, with breakdowns
      # by payment_system, vendor, and fiscal_year.
      def summary(tenant:, **filters)
        rows = detail(tenant: tenant, **filters)

        {
          obligations_analyzed: rows.size,
          total_billed: sum_decimals(rows, :billed_amount),
          total_paid: sum_decimals(rows, :paid_amount),
          total_medicare_equivalent: sum_decimals(rows, :medicare_equivalent),
          total_overpayment_known: sum_decimals(rows.select { |r| r[:recovery_confidence] == "clear" }, :overpayment),
          total_overpayment_stub_estimate: sum_decimals(rows.select { |r| r[:recovery_confidence] == "stub_estimate" }, :overpayment),
          by_payment_system: group_totals(rows, :payment_system),
          by_vendor: group_totals(rows, :vendor_id),
          by_year: group_totals(rows, :fiscal_year)
        }
      end

      # One hash per analyzed obligation. Uses the most recent analysis
      # row per obligation so reanalysis at higher confidence supersedes
      # earlier estimates.
      def detail(tenant:, year: nil, vendor_id: nil, payment_system: nil, recovery_confidence: nil)
        Corvid::TenantContext.with_tenant(tenant) do
          scope = Corvid::PrcOverpaymentAnalysis
                    .joins(:prc_obligation)
                    .where(id: latest_analysis_ids)
          scope = scope.where(corvid_prc_obligations: { fiscal_year: year }) if year
          scope = scope.where(corvid_prc_obligations: { vendor_id: vendor_id }) if vendor_id
          scope = scope.where(payment_system: payment_system) if payment_system
          scope = scope.where(recovery_confidence: recovery_confidence) if recovery_confidence

          scope.includes(:prc_obligation).map { |a| detail_row(a) }
        end
      end

      def to_csv_summary(tenant:, **filters)
        rows = detail(tenant: tenant, **filters)
        groups = rows.group_by { |r| [ r[:fiscal_year], r[:vendor_id], r[:payment_system] ] }

        CSV.generate do |csv|
          csv << SUMMARY_CSV_HEADERS
          groups.each do |(fy, vendor, system), group|
            csv << [
              fy, vendor, system,
              group.size,
              sum_decimals(group, :billed_amount),
              sum_decimals(group, :paid_amount),
              sum_decimals(group, :medicare_equivalent),
              sum_decimals(group.select { |r| r[:recovery_confidence] == "clear" }, :overpayment),
              sum_decimals(group.select { |r| r[:recovery_confidence] == "stub_estimate" }, :overpayment)
            ]
          end
        end
      end

      def to_csv_detail(tenant:, **filters)
        rows = detail(tenant: tenant, **filters)
        CSV.generate do |csv|
          csv << DETAIL_CSV_HEADERS
          rows.each { |r| csv << DETAIL_CSV_HEADERS.map { |h| r[h.to_sym] } }
        end
      end

      def to_json_export(tenant:, **filters)
        applied_filters = filters.compact
        {
          tenant: tenant,
          generated_at: Time.current.iso8601,
          filters: applied_filters,
          summary: summary(tenant: tenant, **filters),
          detail: detail(tenant: tenant, **filters)
        }.to_json
      end

      private

      def latest_analysis_ids
        Corvid::PrcOverpaymentAnalysis
          .group(:prc_obligation_id)
          .maximum(:analyzed_at)
          .map do |obligation_id, max_at|
            Corvid::PrcOverpaymentAnalysis
              .where(prc_obligation_id: obligation_id, analyzed_at: max_at)
              .order(id: :desc)
              .limit(1)
              .pluck(:id)
              .first
          end.compact
      end

      def detail_row(analysis)
        obligation = analysis.prc_obligation
        {
          obligation_id: obligation.obligation_id,
          fiscal_year: obligation.fiscal_year,
          service_date: obligation.service_date,
          vendor_id: obligation.vendor_id,
          procedure_code: obligation.procedure_code,
          payment_system: analysis.payment_system,
          recovery_confidence: analysis.recovery_confidence,
          billed_amount: obligation.billed_amount,
          paid_amount: obligation.paid_amount,
          medicare_equivalent: analysis.medicare_equivalent,
          overpayment: analysis.overpayment,
          analyzer_version: analysis.analyzer_version,
          rate_source: analysis.rate_source,
          rate_source_release: analysis.rate_source_release,
          source_file: obligation.source_file,
          analyzed_at: analysis.analyzed_at
        }
      end

      def sum_decimals(rows, key)
        rows.sum(0.to_d) { |r| r[key] || 0.to_d }
      end

      def group_totals(rows, key)
        rows.group_by { |r| r[key] }.map do |value, group|
          {
            key => value,
            obligations: group.size,
            billed: sum_decimals(group, :billed_amount),
            paid: sum_decimals(group, :paid_amount),
            overpayment: sum_decimals(group, :overpayment)
          }
        end
      end
    end
  end
end
