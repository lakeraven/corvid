# frozen_string_literal: true

require_relative "two_read_find_referral_adapter_delegate"

# Shared setup for #675 stale service_request memo vs fresh find_referral reads.
module MedicaidPriorityAssignmentFreshReadTestHelper
  def install_two_read_find_referral!(referral, first_read_overrides:)
    inner = Corvid.adapter
    delegate = TwoReadFindReferralAdapterDelegate.new(
      inner,
      referral_identifier: referral.referral_identifier,
      first_read_overrides: first_read_overrides
    )
    Corvid.configure { |c| c.adapter = delegate }
    delegate
  end

  def seed_ehr_referral!(referral, patient_identifier:, estimated_cost:, medical_priority_level:)
    Corvid.adapter.add_referral(
      referral.referral_identifier,
      patient_identifier: patient_identifier,
      status: "pending",
      estimated_cost: estimated_cost,
      medical_priority_level: medical_priority_level,
      emergent: false,
      urgent: false,
      chs_approval_status: "P",
      service_requested: "TEST"
    )
  end

  def prime_stale_service_request!(referral, expected_priority:)
    referral.instance_variable_set(:@service_request, nil)
    assert_equal expected_priority, referral.service_request.medical_priority_level
    assert referral.requires_committee?,
      "precondition: first EHR read must require committee so unknown-cost refusal is skipped on stale memo"
  end

  def configure_unknown_cost_two_read_scenario!(referral, patient_identifier:)
    referral.update_columns(estimated_cost_cents: nil, medical_priority: 1, flagged_for_review: false)
    seed_ehr_referral!(
      referral,
      patient_identifier: patient_identifier,
      estimated_cost: nil,
      medical_priority_level: 1
    )
    install_two_read_find_referral!(
      referral,
      first_read_overrides: { medical_priority_level: 3, estimated_cost: nil }
    )
    prime_stale_service_request!(referral, expected_priority: 3)
  end
end
