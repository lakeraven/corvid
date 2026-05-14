# frozen_string_literal: true

require "test_helper"

# FCA / treble-damages language must only appear for Section-506-eligible
# demands; contractual / rural demands at 60+ days fall back to a
# final-notice path that omits the FCA threat.
class Corvid::OverpaymentRecovery::DemandLetterComplianceTest < ActiveSupport::TestCase
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
