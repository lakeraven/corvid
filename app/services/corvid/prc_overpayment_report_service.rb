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
      total_overpayment_known total_overpayment_excluded_stub
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
      total_overpayment_known total_overpayment_excluded_stub
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

      # CSV summary emits only recoverable rows by default — never mixes
      # stub-derived dollars into council-facing totals. Set
      # `include_legacy_stub: true` for a forensic export that includes
      # the legacy stub_estimate column (always zero in the recoverable
      # bucket; populated only when the include_legacy_stub flag is set).
      def to_csv_summary(tenant:, include_legacy_stub: false, **filters)
        csv_summary_from_rows(detail(tenant: tenant, **filters), include_legacy_stub: include_legacy_stub)
      end

      # CSV detail emits only recoverable rows by default. Exceptions
      # are inspected via `to_csv_exceptions` for the ops backlog —
      # the two artifacts have different audiences and shouldn't be
      # mixed into one file.
      def to_csv_detail(tenant:, include_legacy_stub: false, **filters)
        csv_detail_from_rows(detail(tenant: tenant, **filters), include_legacy_stub: include_legacy_stub)
      end

      # Operations-facing backlog: every non-recoverable analyzed
      # obligation, with the reason it fell out of the recoverable
      # bucket. No dollar totals — these are work items, not money.
      EXCEPTIONS_CSV_HEADERS = %w[
        obligation_id fiscal_year service_date vendor_id procedure_code
        payment_system recovery_confidence rate_source currency
        reason
        analyzer_version rate_source_release source_file analyzed_at
      ].freeze

      def to_csv_exceptions(tenant:, **filters)
        csv_exceptions_from_rows(detail(tenant: tenant, **filters))
      end

      # Audit packet: the council-facing / IHS-auditor bundle. Returns a
      # Hash<String, String> mapping filename to content so the caller
      # owns zipping / signing / shipping. All four artifacts are built
      # from a single in-memory row snapshot taken at the top of this
      # method; without that, a write landing between calls could let
      # methodology.json's recoverable count disagree with the row count
      # in detail.csv — unacceptable for an auditor-facing bundle that
      # claims provenance integrity.
      #
      # The methodology.json manifest pins, at the time of the export,
      # the analyzer versions and CMS rate-source releases that
      # contributed dollars, plus the recoverable-rule constants. An
      # auditor reading the packet in 2030 can answer "what was the
      # rule at the time of this packet?" without digging into git.
      def to_audit_packet(tenant:, **filters)
        rows = detail(tenant: tenant, **filters)
        recoverable_rows = rows.select { |r| Corvid::RecoverableRule.recoverable?(r) }
        exception_rows = rows - recoverable_rows

        {
          "summary.csv" => csv_summary_from_rows(rows, include_legacy_stub: false),
          "detail.csv" => csv_detail_from_rows(rows, include_legacy_stub: false),
          "exceptions.csv" => csv_exceptions_from_rows(rows),
          "methodology.json" => methodology_manifest(
            tenant: tenant, filters: filters,
            recoverable_rows: recoverable_rows, exception_rows: exception_rows
          )
        }
      end

      # JSON export defaults to recoverable-only detail so naive integrators
      # can't surface stub-derived dollars by walking the body. Summary
      # always carries the two-bucket structure (recoverable + exceptions).
      # Set `include_legacy_stub: true` for the forensic payload that
      # includes every analyzed row in `detail`.
      def to_json_export(tenant:, include_legacy_stub: false, **filters)
        rows = detail(tenant: tenant, **filters)
        detail_rows = include_legacy_stub ? rows : rows.select { |r| Corvid::RecoverableRule.recoverable?(r) }
        {
          tenant: tenant,
          generated_at: Time.current.iso8601,
          filters: filters.compact,
          summary: serialize_money(summary_from_rows(rows)),
          detail: detail_rows.map { |r| serialize_money(r) }
        }.to_json
      end

      private

      # Build summary CSV from a pre-fetched row set. Same logic as
      # to_csv_summary but doesn't hit the DB — used by to_audit_packet
      # to share one snapshot across all four artifacts.
      def csv_summary_from_rows(all_rows, include_legacy_stub:)
        rows = include_legacy_stub ? all_rows : all_rows.select { |r| Corvid::RecoverableRule.recoverable?(r) }
        groups = rows.group_by { |r| [ r[:fiscal_year], r[:vendor_id], r[:payment_system], r[:currency] ] }
                     .sort_by { |key, _| key.map { |v| v.to_s } }

        CSV.generate do |csv|
          csv << SUMMARY_CSV_HEADERS
          groups.each do |(fy, vendor, system, currency), group|
            recoverable_rows = group.select { |r| Corvid::RecoverableRule.recoverable?(r) }
            stub_rows = group.reject { |r| Corvid::RecoverableRule.recoverable?(r) }
            stub_total = sum_money(stub_rows, :overpayment) || Money.new(0, currency || "USD")
            csv << [
              fy, vendor, system, currency, recoverable_rows.size,
              fmt_money(sum_money(recoverable_rows, :billed_amount)),
              fmt_money(sum_money(recoverable_rows, :paid_amount)),
              fmt_money(sum_money(recoverable_rows, :medicare_equivalent)),
              fmt_money(sum_money(recoverable_rows, :overpayment)),
              fmt_money(stub_total)
            ]
          end
        end
      end

      def csv_detail_from_rows(all_rows, include_legacy_stub:)
        rows = include_legacy_stub ? all_rows : all_rows.select { |r| Corvid::RecoverableRule.recoverable?(r) }
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

      def csv_exceptions_from_rows(all_rows)
        rows = all_rows.reject { |r| Corvid::RecoverableRule.recoverable?(r) }
        CSV.generate do |csv|
          csv << EXCEPTIONS_CSV_HEADERS
          rows.each do |r|
            csv << EXCEPTIONS_CSV_HEADERS.map do |h|
              key = h.to_sym
              if key == :reason
                exception_reason(r)
              else
                r[key]
              end
            end
          end
        end
      end

      # Provenance manifest for the audit packet. Lists every analyzer
      # version that contributed a row (so a single packet that mixes
      # phase_1.5 + phase_2 rows is self-documenting) and every
      # rate_source_release used in the recoverable bucket (the dollars
      # the auditor will actually try to verify). Also pins the rule
      # constants so the packet is interpretable years later even if the
      # engine widens its source set.
      def methodology_manifest(tenant:, filters:, recoverable_rows:, exception_rows:)
        analyzer_versions = (recoverable_rows + exception_rows).map { |r| r[:analyzer_version] }.compact.uniq.sort
        rate_releases = recoverable_rows.map { |r| r[:rate_source_release] }.compact.uniq.sort

        JSON.pretty_generate(
          tenant: tenant,
          generated_at: Time.current.iso8601,
          filters: filters.compact,
          analyzer_versions: analyzer_versions,
          rate_source_releases: rate_releases,
          rule: {
            recoverable_confidence: Corvid::RecoverableRule::RECOVERABLE_CONFIDENCE,
            recoverable_rate_sources: Corvid::RecoverableRule::RECOVERABLE_RATE_SOURCES.to_a
          },
          counts: {
            recoverable: recoverable_rows.size,
            exceptions: exception_rows.size
          }
        )
      end

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

      # Two-bucket summary: the `recoverable` block carries dollar
      # totals computed strictly over rows that pass
      # Corvid::RecoverableRule (clear confidence + real rate source).
      # The `exceptions` block enumerates everything else without
      # dollar totals — counts and reasons only — so it's clear at a
      # glance that those obligations are operational backlog (need
      # dictionary update, real rate ingest, etc.), not citation-ready
      # demand-letter dollars.
      #
      # Within `recoverable`, rows still partition by currency (per
      # ADR 0004 — no auto-FX). Within `exceptions`, rows are grouped
      # by the reason they're not recoverable.
      def summary_from_rows(rows)
        recoverable_rows = rows.select { |r| Corvid::RecoverableRule.recoverable?(r) }
        exception_rows = rows - recoverable_rows

        {
          obligations_analyzed: rows.size,
          recoverable: {
            count: recoverable_rows.size,
            by_currency: recoverable_rows.group_by { |r| r[:currency] }.map { |iso, group| currency_totals(iso, group) },
            by_payment_system: group_totals(recoverable_rows, :payment_system),
            by_vendor: group_totals(recoverable_rows, :vendor_id),
            by_year: group_totals(recoverable_rows, :fiscal_year)
          },
          exceptions: {
            count: exception_rows.size,
            by_reason: exception_rows.group_by { |r| exception_reason(r) }
                                     .transform_values(&:size)
                                     .sort_by { |_, n| -n }
                                     .to_h
          }
        }
      end

      # Recoverable-bucket totals carry the full money roll-up. The
      # column total_overpayment_excluded_stub is the dollars-in-the-
      # exceptions-bucket figure: zero in the council-facing default
      # mode (recoverable rows by definition exclude stub) and
      # populated only by the forensic CSV via include_legacy_stub.
      # New callers wanting the operational backlog should use
      # exceptions.count or to_csv_exceptions instead.
      def currency_totals(iso, rows)
        zero = Money.new(0, iso) if iso
        {
          currency: iso,
          obligations: rows.size,
          total_billed: sum_money(rows, :billed_amount),
          total_paid: sum_money(rows, :paid_amount),
          total_medicare_equivalent: sum_money(rows, :medicare_equivalent),
          total_overpayment_known: sum_money(rows, :overpayment),
          total_overpayment_excluded_stub: zero
        }
      end

      def exception_reason(row)
        confidence = row[:recovery_confidence].to_s
        case confidence
        when "stub_estimate"
          # Both stub paths in PrcOverpaymentAnalyzer set rate_source: :stub,
          # so it can't distinguish loaded canonical stub data from the
          # in-code fallback. rate_source_release is set only on the loaded
          # path (e.g., "stub_v1") and is nil for the fallback path.
          release = row[:rate_source_release].to_s
          release.start_with?("stub") ? "stub_data_loaded" : "stub_fallback"
        when "unmapped_procedure", "unmapped_facility", "no_rate_for_year"
          confidence
        when Corvid::RecoverableRule::RECOVERABLE_CONFIDENCE
          # Clear confidence but a rate_source outside the recoverable set
          # (e.g., a new analyzer label not yet whitelisted). Surface
          # explicitly so ops can decide whether to widen RECOVERABLE_RATE_SOURCES.
          "clear_non_real_source"
        else
          "unknown_#{confidence}"
        end
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

      # Fixed-point amount string for a Money, with the right number of
      # decimal places for that currency — USD/CAD/SEK = 2 ("42000.00"),
      # JOD = 3 ("142.000"), JPY = 0 ("4200"). Reads the exponent from
      # the Money's currency rather than hardcoding 2 so subunit-aware
      # currencies serialize correctly. The currency code itself travels
      # separately in each row's `currency` field.
      def fmt_money(value)
        return nil if value.nil?
        if value.is_a?(Money)
          places = value.currency.exponent
          amount = value.amount
        else
          places = 2
          amount = BigDecimal(value.to_s)
        end
        s = amount.round(places).to_s("F")
        int, frac = s.split(".")
        frac = (frac || "").ljust(places, "0")[0, places]
        places.zero? ? int.to_s : "#{int}.#{frac}"
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
