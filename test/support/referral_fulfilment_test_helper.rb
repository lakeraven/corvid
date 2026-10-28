# frozen_string_literal: true

# Synthetic delivered-care reports for claim submission gates (#675).
module ReferralFulfilmentTestHelper
  def record_delivered_fulfilment!(referral, reported_at: Time.current)
    Corvid::ReferralFulfilment.record_external_report!(
      referral,
      source: "receiving_specialist",
      outcome: "delivered",
      reported_at: reported_at
    )
  end
end
