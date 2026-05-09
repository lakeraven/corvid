# frozen_string_literal: true

require "test_helper"

# Targeted regression tests for two correctness/compliance issues
# called out in PR review of the recovery workflow:
# 1. AuditService must reprice on each claim's date_of_service, not "today".
# 2. FCA / treble-damages language must only appear for Section-506-eligible
#    demands; contractual / rural demands at 60+ days fall back to a
#    final-notice path that omits the FCA threat.
class Corvid::OverpaymentRecoveryCorrectnessTest < ActiveSupport::TestCase
  TENANT = "tnt_recovery_correctness"

  # -- Audit reprices on date_of_service, not today ---------------------------

  test "audit reprices each claim on its date_of_service so a 2025 claim picks the 2025 fee schedule" do
    Corvid::TenantContext.with_tenant(TENANT) do
      Corvid::ZipLocality.create!(zip_code: "98948", locality: "01")
      Corvid::LocalityLookup.clear_cache!
      Corvid::FeeScheduleEntry.create!(
        cpt_code: "99213", locality: "01",
        work_rvu: 1.0, pe_rvu: 1.0, mp_rvu: 0.1,
        work_gpci: 1.0, pe_gpci: 1.0, mp_gpci: 1.0,
        conversion_factor: 30.0,
        effective_date: Date.new(2025, 1, 1)
      )
      Corvid::FeeScheduleEntry.create!(
        cpt_code: "99213", locality: "01",
        work_rvu: 2.0, pe_rvu: 2.0, mp_rvu: 0.2,
        work_gpci: 1.0, pe_gpci: 1.0, mp_gpci: 1.0,
        conversion_factor: 30.0,
        effective_date: Date.new(2026, 1, 1)
      )

      result = Corvid::OverpaymentRecovery::AuditService.audit(
        [ {
          cpt_code: "99213", zip: "98948",
          paid_amount: 100.0,
          provider_npi: "1234567890", provider_name: "Test Provider",
          date_of_service: Date.new(2025, 6, 15)
        } ]
      )
      op = result[:overpayments].first
      refute_nil op
      # 2025 fee schedule yields a smaller medicare_rate than 2026 would.
      # If the audit incorrectly used today's (2026) schedule, the
      # overpayment would be smaller. We assert the rate matches the 2025
      # schedule's expected value.
      expected_2025_rate = (1.0 * 1.0 + 1.0 * 1.0 + 0.1 * 1.0) * 30.0
      assert_in_delta expected_2025_rate, op.medicare_rate.to_f, 0.01,
                      "audit must reprice on the claim's date_of_service, not today"
    end
  end

  # -- FCA escalation is gated to Section 506 ---------------------------------

  test "follow_up_kind for a contractual demand at 60+ days returns :final_notice, not :fca_warning" do
    sent_on = Date.current - 65
    kind = Corvid::OverpaymentRecovery::Timeline.follow_up_kind(
      sent_on: sent_on, today: Date.current, cites_section_506: false
    )
    assert_equal :final_notice, kind,
                 "contractual demand must not trigger FCA escalation"
  end

  test "follow_up_kind for a Section 506 demand at 60+ days still returns :fca_warning" do
    sent_on = Date.current - 65
    kind = Corvid::OverpaymentRecovery::Timeline.follow_up_kind(
      sent_on: sent_on, today: Date.current, cites_section_506: true
    )
    assert_equal :fca_warning, kind
  end

  test "FollowUpGenerator refuses to emit FCA language for a contractual demand even if asked" do
    contractual_demand = Corvid::OverpaymentRecovery::DemandLetterGenerator.generate(
      provider_name: "Rural Co",
      claims: [ { cpt_code: "99213", date_of_service: Date.current,
                  paid_amount: 200.0, medicare_rate: 100.0, overpayment: BigDecimal("100") } ],
      customer_type: :rural,
      medicare_participating: true,
      referral_authorization_terms: "payment limited to Medicare rates"
    )
    refute contractual_demand.cites_section_506

    assert_raises(ArgumentError) do
      Corvid::OverpaymentRecovery::FollowUpGenerator.generate(
        kind: :fca_warning, original_demand: contractual_demand
      )
    end
  end

  test "final_notice follow-up does not warn FCA or reference treble damages" do
    contractual_demand = Corvid::OverpaymentRecovery::DemandLetterGenerator.generate(
      provider_name: "Rural Co",
      claims: [ { cpt_code: "99213", date_of_service: Date.current,
                  paid_amount: 200.0, medicare_rate: 100.0, overpayment: BigDecimal("100") } ],
      customer_type: :rural,
      medicare_participating: true,
      referral_authorization_terms: "payment limited to Medicare rates"
    )
    follow_up = Corvid::OverpaymentRecovery::FollowUpGenerator.generate(
      kind: :final_notice, original_demand: contractual_demand
    )
    assert_equal :final_notice, follow_up.kind
    refute follow_up.warns_fca_liability
    refute follow_up.mentions_treble_damages
    refute_match(/False Claims Act/i, follow_up.body)
    refute_match(/treble/i, follow_up.body)
  end
end
