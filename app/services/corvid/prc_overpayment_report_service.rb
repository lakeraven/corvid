# frozen_string_literal: true

require "bigdecimal"
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
  #
  # Money fields are emitted to CSV/JSON as fixed-point decimal strings
  # (e.g., "42000.00"), never BigDecimal#to_s scientific notation —
  # that form would silently break audit-tool ingestion and rounding-
  # sensitive recovery math downstream.
  module PrcOverpaymentReportService
    SUMMARY_CSV_HEADERS = %w[
      fiscal_year vendor_id payment_system currency
      obligations_count
      total_billed total_paid total_medicare_equivalent
      total_overpayment_known total_overpayment_stub_estimate
    ].freeze

    DETAIL_CSV_HEADERS = %w[
      obligation_id fiscal_year service_date vendor_id procedure_code
      payment_system recovery_confidence currency
      billed_amount paid_amount medicare_equivalent overpayment
      analyzer_version rate_source rate_source_release
      source_file analyzed_at
    ].freeze

    MONEY_KEYS = %i[
      billed_amount paid_amount medicare_equivalent overpayment
      total_billed total_paid total_medicare_equivalent
      total_overpayment_known total_overpayment_stub_estimate
      billed paid
    ].freeze

    class << self
      # Aggregate totals across the filtered analysis set, with breakdowns
      # by payment_system, vendor, and fiscal_year.
      def summary(tenant:, **filters)
        summary_from_rows(detail(tenant: tenant, **filters))
      end

      # One hash per analyzed obligation. Uses the most recent analysis
      # row per obligation so reanalysis at higher confidence supersedes
      # earlier estimates. Output is deterministically ordered by
      # (fiscal_year, vendor_id, payment_system, obligation_id) so that
      # two exports of unchanged data produce byte-identical artifacts —
      # diffs of the report itself are then meaningful audit signal.
      #
      # `fiscal_year:` filters on the federal-fiscal-year column; `year:`
      # is accepted as a deprecated alias for callers that pre-date the
      # rename, since calendar/fiscal ambiguity matters in PRC.
      def detail(tenant:, fiscal_year: nil, year: nil, vendor_id: nil, payment_system: nil, recovery_confidence: nil)
        fy = fiscal_year || year

        Corvid::TenantContext.with_tenant(tenant) do
          scope = Corvid::PrcOverpaymentAnalysis
                    .joins(:prc_obligation)
                    .where(id: latest_analysis_ids)
          scope = scope.where(corvid_prc_obligations: { fiscal_year: fy }) if fy
          scope = scope.where(corvid_prc_obligations: { vendor_id: vendor_id }) if vendor_id
          scope = scope.where(payment_system: payment_system) if payment_system
          scope = scope.where(recovery_confidence: recovery_confidence) if recovery_confidence

          scope
            .includes(:prc_obligation)
            .order(Arel.sql(
              "corvid_prc_obligations.fiscal_year ASC NULLS LAST, " \
              "corvid_prc_obligations.vendor_id ASC NULLS LAST, " \
              "corvid_prc_overpayment_analyses.payment_system ASC NULLS LAST, " \
              "corvid_prc_obligations.obligation_id ASC"
            ))
            .map { |a| detail_row(a) }
        end
      end

      def to_csv_summary(tenant:, **filters)
        rows = detail(tenant: tenant, **filters)
        groups = rows.group_by { |r| [ r[:fiscal_year], r[:vendor_id], r[:payment_system], r[:currency] ] }
                     .sort_by { |key, _| key.map { |v| v.to_s } }

        CSV.generate do |csv|
          csv << SUMMARY_CSV_HEADERS
          groups.each do |(fy, vendor, system, currency), group|
            csv << [
              fy, vendor, system, currency, group.size,
              fmt_money(sum_money(group, :billed_amount)),
              fmt_money(sum_money(group, :paid_amount)),
              fmt_money(sum_money(group, :medicare_equivalent)),
              fmt_money(sum_money(group.select { |r| r[:recovery_confidence] == "clear" }, :overpayment)),
              fmt_money(sum_money(group.select { |r| r[:recovery_confidence] == "stub_estimate" }, :overpayment))
            ]
          end
        end
      end

      def to_csv_detail(tenant:, **filters)
        rows = detail(tenant: tenant, **filters)
        CSV.generate do |csv|
          csv << DETAIL_CSV_HEADERS
          rows.each do |r|
            csv << DETAIL_CSV_HEADERS.map do |h|
              key = h.to_sym
              MONEY_KEYS.include?(key) ? fmt_money(r[key]) : r[key]
            end
          end
        end
      end

      # Computes detail once and derives summary from the same in-memory
      # set so the JSON payload's summary and detail are consistent and
      # we don't repeat DB work — important for large tenants where
      # detail() is the dominant cost.
      def to_json_export(tenant:, **filters)
        rows = detail(tenant: tenant, **filters)
        {
          tenant: tenant,
          generated_at: Time.current.iso8601,
          filters: filters.compact,
          summary: serialize_money(summary_from_rows(rows)),
          detail: rows.map { |r| serialize_money(r) }
        }.to_json
      end

      private

      # Latest-analysis-per-obligation expressed as a Postgres DISTINCT ON
      # subquery. Embedding it in `WHERE id IN (...)` keeps the whole
      # detail() lookup a single round trip — no N+1 SELECT-per-obligation
      # and no Ruby-side roundtrip materializing every id. The id
      # tiebreaker keeps results deterministic when two analyses share
      # the same analyzed_at down to the microsecond.
      def latest_analysis_ids
        Corvid::PrcOverpaymentAnalysis
          .select(Arel.sql("DISTINCT ON (prc_obligation_id) corvid_prc_overpayment_analyses.id"))
          .order(Arel.sql("prc_obligation_id, analyzed_at DESC, id DESC"))
      end

      # Summaries always partition rows by currency before summing — per
      # ADR 0004, mixed-currency aggregation never auto-FXes. A single-
      # currency tenant produces one entry under `by_currency`; a future
      # multi-currency tenant produces one entry per ISO code, side by
      # side, with their own Money totals.
      def summary_from_rows(rows)
        {
          obligations_analyzed: rows.size,
          by_currency: rows.group_by { |r| r[:currency] }.map { |iso, group| currency_totals(iso, group) },
          by_payment_system: group_totals(rows, :payment_system),
          by_vendor: group_totals(rows, :vendor_id),
          by_year: group_totals(rows, :fiscal_year)
        }
      end

      def currency_totals(iso, rows)
        {
          currency: iso,
          obligations: rows.size,
          total_billed: sum_money(rows, :billed_amount),
          total_paid: sum_money(rows, :paid_amount),
          total_medicare_equivalent: sum_money(rows, :medicare_equivalent),
          total_overpayment_known: sum_money(rows.select { |r| r[:recovery_confidence] == "clear" }, :overpayment),
          total_overpayment_stub_estimate: sum_money(rows.select { |r| r[:recovery_confidence] == "stub_estimate" }, :overpayment)
        }
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
          currency: obligation.currency_iso,
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

      # Sum a column of Money values across rows. Callers must hand us a
      # set that's already single-currency (we partition by currency
      # before summing). Mixed-currency input raises Money's bank error
      # by design — that's the loud-fail signal that something forgot
      # to bucket by ISO code.
      def sum_money(rows, key)
        values = rows.map { |r| r[key] }.compact
        return nil if values.empty?
        values.reduce(:+)
      end

      # Group breakdowns also partition by currency so the inner sums
      # are guaranteed single-currency.
      def group_totals(rows, key)
        rows.group_by { |r| [ r[key], r[:currency] ] }.map do |(value, currency), group|
          {
            key => value,
            currency: currency,
            obligations: group.size,
            billed: sum_money(group, :billed_amount),
            paid: sum_money(group, :paid_amount),
            overpayment: sum_money(group, :overpayment)
          }
        end
      end

      # Fixed-point amount string for a Money. Drops symbol and
      # thousands-separator and forces two decimal places — consumers
      # (Excel, audit tools, recovery-letter mail merges) want "42000.00",
      # not "$42,000.00" or "0.42E5". Currency code travels separately
      # in the JSON `currency` field on each row.
      def fmt_money(value)
        return nil if value.nil?
        amount = value.is_a?(Money) ? value.amount : BigDecimal(value.to_s)
        s = amount.round(2).to_s("F")
        int, frac = s.split(".")
        frac = (frac || "").ljust(2, "0")[0, 2]
        "#{int}.#{frac}"
      end

      # Walks a hash/array tree, converting any Money values to fixed-point
      # strings before JSON encoding (ActiveSupport's encoder would otherwise
      # serialize Money via to_s, which is symbol-formatted and locale-y).
      def serialize_money(value)
        case value
        when Money
          fmt_money(value)
        when Hash
          value.each_with_object({}) do |(k, v), out|
            out[k] = serialize_money(v)
          end
        when Array
          value.map { |v| serialize_money(v) }
        else
          value
        end
      end
    end
  end
end
