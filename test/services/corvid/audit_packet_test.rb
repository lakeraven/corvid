# frozen_string_literal: true

require "test_helper"
require "csv"
require "json"

# An audit packet is the council-facing / IHS-auditor-facing bundle that
# ties together every report-layer artifact (summary, recoverable detail,
# exceptions, methodology) with shared provenance. Same recoverable-rule
# gate as the demand letter — stub-derived dollars never appear in the
# recoverable-detail or summary, only in the exceptions queue.
class Corvid::AuditPacketTest < ActiveSupport::TestCase
  TENANT = "tnt_audit_packet"

  setup do
    Corvid::TenantContext.with_tenant(TENANT) do
      recoverable_ob = Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-AP-REAL",
        billed_amount_cents: 2_000_00,
        paid_amount_cents: 1_500_00,
        currency_iso: "USD",
        fiscal_year: 2026,
        imported_at: Time.current
      )
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: recoverable_ob,
        analyzer_version: "phase_1.5",
        rate_source_release: "cms_fy2026_final_rule",
        payment_system: "ipps", rate_source: "real",
        recovery_confidence: "clear",
        currency_iso: "USD",
        medicare_equivalent_cents: 1_000_00,
        overpayment_cents: 500_00,
        analyzed_at: Time.current
      )

      stub_ob = Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-AP-STUB",
        billed_amount_cents: 2_000_00,
        paid_amount_cents: 1_500_00,
        currency_iso: "USD",
        fiscal_year: 2026,
        imported_at: Time.current
      )
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: stub_ob,
        analyzer_version: "phase_1.5",
        rate_source_release: "stub_v1",
        payment_system: "ipps", rate_source: "stub",
        recovery_confidence: "stub_estimate",
        currency_iso: "USD",
        overpayment_cents: 999_999_900,
        analyzed_at: Time.current
      )
    end
  end

  test "to_audit_packet returns the four expected entries" do
    packet = Corvid::PrcOverpaymentReportService.to_audit_packet(tenant: TENANT)
    assert_equal %w[summary.csv detail.csv exceptions.csv methodology.json].sort,
                 packet.keys.sort
    packet.each_value { |content| refute_nil content; refute content.empty? }
  end

  test "detail.csv carries only recoverable rows; stub stays out" do
    packet = Corvid::PrcOverpaymentReportService.to_audit_packet(tenant: TENANT)
    table = CSV.parse(packet["detail.csv"], headers: true)
    obligation_ids = table.map { |r| r["obligation_id"] }
    assert_equal [ "OBL-AP-REAL" ], obligation_ids,
                 "audit packet detail must mirror the council-facing CSV — no stub rows"
  end

  test "exceptions.csv enumerates non-recoverable rows" do
    packet = Corvid::PrcOverpaymentReportService.to_audit_packet(tenant: TENANT)
    table = CSV.parse(packet["exceptions.csv"], headers: true)
    obligation_ids = table.map { |r| r["obligation_id"] }
    assert_includes obligation_ids, "OBL-AP-STUB"
  end

  test "methodology.json carries provenance: analyzer versions, rate-source releases, rule" do
    packet = Corvid::PrcOverpaymentReportService.to_audit_packet(tenant: TENANT)
    meta = JSON.parse(packet["methodology.json"])

    assert_equal TENANT, meta["tenant"]
    refute_nil meta["generated_at"]
    assert_includes meta["analyzer_versions"], "phase_1.5",
                    "must list every analyzer version that contributed to this packet"
    assert_includes meta["rate_source_releases"], "cms_fy2026_final_rule",
                    "must list every CMS release used in the recoverable bucket"
    # The rule constants travel with the packet so an auditor reading it
    # in 2030 can answer 'what was the rule at the time of this packet?'
    assert_equal "clear", meta["rule"]["recoverable_confidence"]
    assert_includes meta["rule"]["recoverable_rate_sources"], "real"
    # Recoverable/exceptions counts come along so the manifest is
    # self-contained (no cross-reference to detail.csv required).
    assert_equal 1, meta["counts"]["recoverable"]
    assert_equal 1, meta["counts"]["exceptions"]
  end

  test "methodology.json filters reflect the call arguments" do
    packet = Corvid::PrcOverpaymentReportService.to_audit_packet(
      tenant: TENANT, fiscal_year: 2026
    )
    meta = JSON.parse(packet["methodology.json"])
    assert_equal({ "fiscal_year" => 2026 }, meta["filters"])
  end

  # -- Snapshot consistency --
  # If a new analysis row lands during packet generation, the four
  # artifacts must all reflect the same snapshot — an auditor-facing
  # bundle can't have the manifest claim "1 recoverable" while
  # detail.csv shows 2.

  test "to_audit_packet calls detail exactly once across all artifacts" do
    call_count = 0
    original = Corvid::PrcOverpaymentReportService.method(:detail)
    Corvid::PrcOverpaymentReportService.define_singleton_method(:detail) do |**kwargs|
      call_count += 1
      original.call(**kwargs)
    end

    begin
      Corvid::PrcOverpaymentReportService.to_audit_packet(tenant: TENANT)
    ensure
      Corvid::PrcOverpaymentReportService.singleton_class.send(:remove_method, :detail)
      Corvid::PrcOverpaymentReportService.define_singleton_method(:detail, original)
    end

    assert_equal 1, call_count,
                 "all four packet artifacts must share one row snapshot — calling " \
                 "detail() per artifact lets a concurrent write make the manifest " \
                 "disagree with detail.csv"
  end

  test "manifest count and detail.csv row count stay aligned" do
    packet = Corvid::PrcOverpaymentReportService.to_audit_packet(tenant: TENANT)
    meta = JSON.parse(packet["methodology.json"])
    detail_rows = CSV.parse(packet["detail.csv"], headers: true)
    exception_rows = CSV.parse(packet["exceptions.csv"], headers: true)

    assert_equal meta["counts"]["recoverable"], detail_rows.size,
                 "manifest recoverable count must equal detail.csv row count"
    assert_equal meta["counts"]["exceptions"], exception_rows.size,
                 "manifest exceptions count must equal exceptions.csv row count"
  end
end
