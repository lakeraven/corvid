# frozen_string_literal: true

require "test_helper"

# A Section-506 demand letter cites the False Claims Act and threatens
# treble damages, so a stub-derived dollar that slips into this path is
# the highest-stakes failure mode in the system. These tests pin the
# guard: DemandLetterGenerator.generate_from_analyses must refuse the
# whole batch if any input fails Corvid::RecoverableRule.
class Corvid::OverpaymentRecovery::DemandLetterRecoverableGuardTest < ActiveSupport::TestCase
  TENANT = "tnt_demand_guard"

  setup do
    Corvid::TenantContext.with_tenant(TENANT) do
      @recoverable_ob = make_obligation("OBL-REAL-1", procedure_code: "99213")
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: @recoverable_ob,
        analyzer_version: "phase_1.5",
        rate_source_release: "cms_fy2026_final_rule",
        payment_system: "pfs", rate_source: "real",
        recovery_confidence: "clear",
        currency_iso: "USD",
        medicare_equivalent_cents: 5_000_00,
        overpayment_cents: 2_500_00,
        analyzed_at: Time.current
      )

      @stub_ob = make_obligation("OBL-STUB-1", procedure_code: "99214")
      Corvid::PrcOverpaymentAnalysis.create!(
        prc_obligation: @stub_ob,
        analyzer_version: "phase_1.5",
        rate_source_release: "stub_v1",
        payment_system: "ipps", rate_source: "stub",
        recovery_confidence: "stub_estimate",
        currency_iso: "USD",
        medicare_equivalent_cents: 100_00,
        overpayment_cents: 1_000_000_00,
        analyzed_at: Time.current
      )
    end
  end

  test "generate_from_analyses builds a Section 506 letter from recoverable rows" do
    Corvid::TenantContext.with_tenant(TENANT) do
      letter = Corvid::OverpaymentRecovery::DemandLetterGenerator.generate_from_analyses(
        provider_name: "Real Provider",
        provider_npi: "1234567890",
        analyses: [ recoverable_analysis ]
      )
      assert letter.cites_section_506
      assert letter.cites_fca
      assert_equal 1, letter.claims.size
      assert_in_delta 2_500.00, letter.total_demanded.to_f, 0.01
      assert letter.body.include?("99213"), "claim CPT must appear in body"
    end
  end

  test "generate_from_analyses refuses the batch if ANY row is non-recoverable" do
    Corvid::TenantContext.with_tenant(TENANT) do
      err = assert_raises(Corvid::OverpaymentRecovery::DemandLetterGenerator::NotRecoverableError) do
        Corvid::OverpaymentRecovery::DemandLetterGenerator.generate_from_analyses(
          provider_name: "Mixed Provider",
          analyses: [ recoverable_analysis, stub_analysis ]
        )
      end
      msg = err.message
      assert_includes msg, "OBL-STUB-1",
                      "error must name the offending obligation so ops can find it fast"
      refute_includes msg, "OBL-REAL-1",
                      "error must list only the rows that failed the rule, not the whole batch"
    end
  end

  test "generate_from_analyses refuses an all-stub batch with rule-specific reason" do
    Corvid::TenantContext.with_tenant(TENANT) do
      err = assert_raises(Corvid::OverpaymentRecovery::DemandLetterGenerator::NotRecoverableError) do
        Corvid::OverpaymentRecovery::DemandLetterGenerator.generate_from_analyses(
          provider_name: "Stub Provider",
          analyses: [ stub_analysis ]
        )
      end
      # Error carries the recovery_confidence + rate_source so ops triage
      # knows whether to ingest real rate data or update the dictionary.
      assert_match(/recovery_confidence=stub_estimate/, err.message)
      assert_match(/rate_source="?stub/, err.message)
    end
  end

  test "generate_from_analyses raises if the analyses array is empty" do
    assert_raises(ArgumentError) do
      Corvid::OverpaymentRecovery::DemandLetterGenerator.generate_from_analyses(
        provider_name: "Nobody", analyses: []
      )
    end
  end

  private

  def recoverable_analysis
    Corvid::PrcOverpaymentAnalysis.find_by!(prc_obligation: @recoverable_ob)
  end

  def stub_analysis
    Corvid::PrcOverpaymentAnalysis.find_by!(prc_obligation: @stub_ob)
  end

  def make_obligation(id, procedure_code:)
    Corvid::PrcObligation.create!(
      facility_identifier: "SEA",
      obligation_id: id,
      procedure_code: procedure_code,
      billed_amount_cents: 1_000_00,
      paid_amount_cents: 7_500_00,
      currency_iso: "USD",
      fiscal_year: 2026,
      service_date: Date.new(2026, 3, 1),
      imported_at: Time.current
    )
  end
end
