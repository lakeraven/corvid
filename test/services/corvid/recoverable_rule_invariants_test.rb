# frozen_string_literal: true

require "test_helper"
require "csv"
require "json"

# Council-facing contract tests. These assert the "recoverable" rule
# can't be silently weakened — every test here protects against a
# class of bug that would put stub-derived numbers in front of an
# auditor or tribal council.
class Corvid::RecoverableRuleInvariantsTest < ActiveSupport::TestCase
  TENANT = "tnt_recov_inv"

  setup do
    Corvid::TenantContext.with_tenant(TENANT) do
      # Recoverable row: real CMS data, clear confidence.
      recoverable_ob = make_obligation("OBL-REAL", year: 2026)
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: recoverable_ob,
        analyzer_version: "phase_1.5",
        rate_source_release: "cms_fy2026_final_rule",
        payment_system: "ipps", rate_source: "real",
        recovery_confidence: "clear",
        currency_iso: "USD",
        medicare_equivalent_cents: 1_000_000, # $10,000
        overpayment_cents: 500_000, # $5,000
        analyzed_at: Time.current
      )

      # Stub-derived row: directional dollars but never recoverable.
      stub_ob = make_obligation("OBL-STUB", year: 2026)
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: stub_ob,
        analyzer_version: "phase_1.5",
        rate_source_release: "stub_v1",
        payment_system: "ipps", rate_source: "stub",
        recovery_confidence: "stub_estimate",
        currency_iso: "USD",
        medicare_equivalent_cents: 100_000, # $1,000 — must NOT count
        overpayment_cents: 999_999_900, # $9,999,999 — pathological — must NOT count
        analyzed_at: Time.current
      )

      # Unmapped procedure: no rate at all.
      unmapped_ob = make_obligation("OBL-UNMAPPED", year: 2026)
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: unmapped_ob,
        analyzer_version: "phase_1.5",
        payment_system: nil, rate_source: nil,
        recovery_confidence: "unmapped_procedure",
        currency_iso: "USD",
        analyzed_at: Time.current
      )
    end
  end

  # -- Invariant 1: no :clear result can have rate_source :stub --

  test "no PrcOverpaymentAnalysis row may have recovery_confidence=clear AND rate_source=stub" do
    Corvid::TenantContext.with_tenant(TENANT) do
      bad_row = Corvid::PrcOverpaymentAnalysis.where(
        recovery_confidence: "clear", rate_source: "stub"
      )
      assert_empty bad_row,
                   "a :clear / :stub row would let stub-derived data slip through " \
                   "every council-facing export — Corvid::RecoverableRule gates on " \
                   "(confidence==clear AND source==real), and stub-source rows must " \
                   "stay in the exceptions backlog"
    end
  end

  # -- Invariant 2: summary totals match recoverable rows only --

  test "summary totals exclude stub-derived dollars" do
    summary = Corvid::PrcOverpaymentReportService.summary(tenant: TENANT)

    usd = summary[:recoverable][:by_currency].find { |b| b[:currency] == "USD" }
    refute_nil usd
    assert_equal Money.from_amount(5_000, "USD"), usd[:total_overpayment_known],
                 "only the recoverable row's $5,000 contributes; the stub row's " \
                 "$9,999,999 must NOT appear in any council-facing total"
    assert_equal 1, summary[:recoverable][:count]

    assert_equal 2, summary[:exceptions][:count]
    assert summary[:exceptions][:by_reason].keys.any?,
           "exceptions roll up by reason (stub_data_loaded, unmapped_procedure, etc.)"
  end

  # -- Invariant 3: detail CSV excludes non-recoverable rows by default --

  test "to_csv_detail default emits only recoverable rows" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_detail(tenant: TENANT)
    table = CSV.parse(csv, headers: true)
    obligation_ids = table.map { |r| r["obligation_id"] }
    assert_equal [ "OBL-REAL" ], obligation_ids,
                 "stub and unmapped obligations belong in the exceptions report, " \
                 "not the council-facing detail CSV"
  end

  # -- Invariant 4: summary CSV's excluded_stub column is zero by default --

  test "to_csv_summary default has zero excluded_stub dollars" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_summary(tenant: TENANT)
    table = CSV.parse(csv, headers: true)
    table.each do |row|
      assert_equal "0.00", row["total_overpayment_excluded_stub"],
                   "default CSV must never carry stub dollars; got #{row.inspect}"
    end
  end

  # -- Invariant 5: forensic flag exposes the legacy stub column --

  test "include_legacy_stub: true CSV detail includes non-recoverable rows" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_detail(tenant: TENANT, include_legacy_stub: true)
    table = CSV.parse(csv, headers: true)
    assert table.size >= 3,
           "include_legacy_stub: true is the forensic export — all analyzed rows"
  end

  # -- Invariant 6: exceptions CSV enumerates non-recoverable rows by reason --

  test "to_csv_exceptions enumerates the backlog without dollars" do
    csv = Corvid::PrcOverpaymentReportService.to_csv_exceptions(tenant: TENANT)
    table = CSV.parse(csv, headers: true)

    obligation_ids = table.map { |r| r["obligation_id"] }.sort
    assert_equal [ "OBL-STUB", "OBL-UNMAPPED" ], obligation_ids

    reasons = table.map { |r| r["reason"] }.sort
    assert_includes reasons, "stub_data_loaded"
    assert_includes reasons, "unmapped_procedure"

    refute_includes table.headers, "total_overpayment",
                    "exceptions are work items, not money"
    refute_includes table.headers, "total_overpayment_known"
  end

  # -- Invariant 7: JSON detail defaults to recoverable-only --

  test "to_json_export default detail excludes stub rows" do
    json = Corvid::PrcOverpaymentReportService.to_json_export(tenant: TENANT)
    parsed = JSON.parse(json)
    ids = parsed["detail"].map { |r| r["obligation_id"] }
    assert_equal [ "OBL-REAL" ], ids,
                 "JSON detail must mirror CSV detail — naive integrators must not " \
                 "be able to surface stub-derived dollars by walking the body"
  end

  test "to_json_export with include_legacy_stub: true emits all rows" do
    json = Corvid::PrcOverpaymentReportService.to_json_export(
      tenant: TENANT, include_legacy_stub: true
    )
    parsed = JSON.parse(json)
    assert parsed["detail"].size >= 3,
           "forensic JSON export carries every analyzed row"
  end

  # -- Invariant 8: summary CSV count matches recoverable dollars even in forensic mode --

  test "to_csv_summary obligations_count equals recoverable-only count in forensic mode" do
    # Add a stub-only obligation with a distinct vendor so it forms its
    # own grouping row and we can assert the count semantics directly.
    Corvid::TenantContext.with_tenant(TENANT) do
      ob = make_obligation("OBL-STUB-ONLY", year: 2026)
      ob.update!(vendor_id: "VEND-STUB-ONLY")
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_1.5",
        rate_source_release: "stub_v1",
        payment_system: "ipps", rate_source: "stub",
        recovery_confidence: "stub_estimate",
        currency_iso: "USD",
        overpayment_cents: 700_000_00,
        analyzed_at: Time.current
      )
    end

    csv = Corvid::PrcOverpaymentReportService.to_csv_summary(
      tenant: TENANT, include_legacy_stub: true
    )
    table = CSV.parse(csv, headers: true)
    stub_only_row = table.find { |r| r["vendor_id"] == "VEND-STUB-ONLY" }
    refute_nil stub_only_row, "forensic mode must emit a row for the stub-only group"
    assert_equal 0, stub_only_row["obligations_count"].to_i,
                 "stub-only group has zero recoverable rows; count must reflect that " \
                 "so a spreadsheet reader can't divide stub-inclusive counts by " \
                 "recoverable-only dollar totals"
  end

  # -- Invariant 8.5: missing_service_date is a distinct exception reason --

  test "to_csv_exceptions labels nil-service-date rows as missing_service_date" do
    Corvid::TenantContext.with_tenant(TENANT) do
      ob = Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-NO-SD",
        billed_amount_cents: 2_000_00,
        paid_amount_cents: 1_500_00,
        currency_iso: "USD",
        fiscal_year: 2026,
        service_date: nil,
        imported_at: Time.current
      )
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_1.5",
        payment_system: nil, rate_source: nil,
        recovery_confidence: "missing_service_date",
        currency_iso: "USD",
        analyzed_at: Time.current
      )
    end

    csv = Corvid::PrcOverpaymentReportService.to_csv_exceptions(tenant: TENANT)
    table = CSV.parse(csv, headers: true)
    row = table.find { |r| r["obligation_id"] == "OBL-NO-SD" }
    refute_nil row, "nil-service-date row must appear in exceptions"
    assert_equal "missing_service_date", row["reason"],
                 "distinct reason so ops triage points at the obligation, " \
                 "not at fee-schedule coverage"
  end

  # -- Invariant 9: clear_non_real_source reason is explicit, not "unknown_clear" --

  test "to_csv_exceptions labels clear + non-real source as clear_non_real_source" do
    Corvid::TenantContext.with_tenant(TENANT) do
      ob = make_obligation("OBL-CLEAR-NONREAL", year: 2026)
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_1.5",
        rate_source_release: "cms_fy2026_final_rule",
        payment_system: "ipps", rate_source: "fictional_label",
        recovery_confidence: "clear",
        currency_iso: "USD",
        medicare_equivalent_cents: 1_000_000,
        overpayment_cents: 500_000,
        analyzed_at: Time.current
      )
    end

    csv = Corvid::PrcOverpaymentReportService.to_csv_exceptions(tenant: TENANT)
    table = CSV.parse(csv, headers: true)
    nonreal_row = table.find { |r| r["obligation_id"] == "OBL-CLEAR-NONREAL" }
    refute_nil nonreal_row, "clear+non-real row must appear in exceptions, not recoverable"
    assert_equal "clear_non_real_source", nonreal_row["reason"],
                 "ops triage needs an explicit label here — 'unknown_clear' would " \
                 "look like a data bug rather than a whitelist gap"
  end

  # -- Invariant 10: PrcOverpaymentAnalysis#recoverable? matches the rule --

  test "recoverable? predicate matches Corvid::RecoverableRule" do
    Corvid::TenantContext.with_tenant(TENANT) do
      real_row = Corvid::PrcOverpaymentAnalysis.find_by(rate_source: "real")
      assert real_row.recoverable?
      assert Corvid::RecoverableRule.recoverable?(real_row)

      stub_row = Corvid::PrcOverpaymentAnalysis.find_by(rate_source: "stub")
      refute stub_row.recoverable?
      refute Corvid::RecoverableRule.recoverable?(stub_row)
    end
  end

  # -- Invariant 11: model scope agrees with predicate over the rate_source set --

  test "PrcOverpaymentAnalysis.recoverable scope reads the same set as the predicate" do
    Corvid::TenantContext.with_tenant(TENANT) do
      scope_ids = Corvid::PrcOverpaymentAnalysis.recoverable.pluck(:id).sort
      predicate_ids = Corvid::PrcOverpaymentAnalysis
                        .all
                        .select { |a| Corvid::RecoverableRule.recoverable?(a) }
                        .map(&:id).sort
      assert_equal predicate_ids, scope_ids,
                   "model scope and rule predicate must read the same source set " \
                   "so model-level filtering can't diverge if a second \"real\" " \
                   "label is added to RECOVERABLE_RATE_SOURCES"
    end
  end

  # -- Invariant 12: multi-label set propagates through scope, predicate, and reports --

  # Pin the contract under the *intended* multi-label state: when a
  # future analyzer emits a second "real" label, widening
  # RECOVERABLE_RATE_SOURCES alone must be enough to flow it through
  # the model scope, the predicate, AND the report layer in lockstep.
  # If any of those three reads the set independently or hardcodes
  # "real", the dataset-level disagreement shows up here.
  test "widening RECOVERABLE_RATE_SOURCES flows through scope, predicate, and report" do
    Corvid::TenantContext.with_tenant(TENANT) do
      ob = make_obligation("OBL-CMS-REAL", year: 2026)
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: ob,
        analyzer_version: "phase_2",
        rate_source_release: "cms_fy2026_final_rule",
        payment_system: "ipps", rate_source: "cms_real",
        recovery_confidence: "clear",
        currency_iso: "USD",
        medicare_equivalent_cents: 2_000_000,
        overpayment_cents: 750_000,
        analyzed_at: Time.current
      )
    end

    # With the current single-label set, the cms_real row must be in exceptions.
    refute_includes recoverable_obligation_ids, "OBL-CMS-REAL",
                    "baseline: cms_real not yet whitelisted, must read as exception"

    with_recoverable_rate_sources(%w[real cms_real]) do
      ids = recoverable_obligation_ids
      assert_includes ids, "OBL-CMS-REAL",
                      "widened set must flow through the report's recoverable filter"
      assert_includes ids, "OBL-REAL",
                      "original recoverable row must still pass under the wider set"

      Corvid::TenantContext.with_tenant(TENANT) do
        scope_ids = Corvid::PrcOverpaymentAnalysis.recoverable.pluck(:id).sort
        predicate_ids = Corvid::PrcOverpaymentAnalysis
                          .all
                          .select { |a| Corvid::RecoverableRule.recoverable?(a) }
                          .map(&:id).sort
        assert_equal predicate_ids, scope_ids,
                     "scope and predicate must agree under a multi-label set"
      end
    end

    # After restore, the cms_real row falls back to exceptions —
    # proves the swap was clean and nothing latched the wider set.
    refute_includes recoverable_obligation_ids, "OBL-CMS-REAL",
                    "restore: cms_real must return to exceptions"
  end

  private

  # Read the obligation_ids the report layer considers recoverable
  # (i.e. what reaches the council-facing CSV detail).
  def recoverable_obligation_ids
    csv = Corvid::PrcOverpaymentReportService.to_csv_detail(tenant: TENANT)
    CSV.parse(csv, headers: true).map { |r| r["obligation_id"] }
  end

  # Temporarily swap the recoverable rate_source set so we can exercise
  # the multi-label state without permanently widening production rules.
  # `remove_const` + `const_set` avoids Ruby's "already initialized" warning.
  def with_recoverable_rate_sources(labels)
    original = Corvid::RecoverableRule::RECOVERABLE_RATE_SOURCES
    Corvid::RecoverableRule.send(:remove_const, :RECOVERABLE_RATE_SOURCES)
    Corvid::RecoverableRule.const_set(:RECOVERABLE_RATE_SOURCES, labels.freeze)
    yield
  ensure
    Corvid::RecoverableRule.send(:remove_const, :RECOVERABLE_RATE_SOURCES)
    Corvid::RecoverableRule.const_set(:RECOVERABLE_RATE_SOURCES, original)
  end


  def make_obligation(id, year:)
    Corvid::PrcObligation.create!(
      facility_identifier: "SEA",
      obligation_id: id,
      billed_amount_cents: 2_000_000,
      paid_amount_cents: 1_500_000,
      currency_iso: "USD",
      fiscal_year: year,
      imported_at: Time.current
    )
  end
end
