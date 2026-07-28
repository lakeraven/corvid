# frozen_string_literal: true

require "test_helper"

module Corvid
  # Regression: PrcReferral#sync_status_to_ehr is fired as an AASM after-callback
  # on authorize / mark_denied / mark_deferred. Adapters that legitimately
  # don't own referrals (e.g. tribal-enrollment backends) raise
  # NotImplementedError, which descends from ScriptError — not StandardError —
  # so a bare `rescue` lets it bubble out and leaves the transition
  # half-applied (state saved, callback unwound).
  class PrcReferralSyncTest < ActiveSupport::TestCase
    TENANT = "tnt_sync"
    FACILITY = "fac_sync"

    setup do
      @original_adapter = Corvid.adapter
    end

    teardown do
      Corvid.configure { |c| c.adapter = @original_adapter }
    end

    test "sync_status_to_ehr swallows NotImplementedError from adapter" do
      with_tenant(TENANT) do
        referral = build_draft_referral
        swap_adapter(update_referral: ->(*) { raise NotImplementedError, "not my table" })
        assert_nothing_raised { assert_equal false, referral.send(:sync_status_to_ehr) }
      end
    end

    test "mark_denied! completes when adapter raises NotImplementedError" do
      with_tenant(TENANT) do
        referral = referral_in(:eligibility_review)
        swap_adapter(update_referral: ->(*) { raise NotImplementedError, "not my table" })
        assert_nothing_raised { referral.mark_denied! }
        assert_equal "denied", referral.reload.status
      end
    end

    private

    def build_draft_referral
      kase = Case.create!(patient_identifier: "pt_sync", facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        estimated_cost: 5_000
      )
    end

    def referral_in(target)
      r = build_draft_referral
      Corvid.adapter.add_referral(r.referral_identifier,
        patient_identifier: "pt_sync", status: "pending",
        estimated_cost: 5_000, emergent: false, urgent: false,
        chs_approval_status: "P", service_requested: "TEST")
      r.submit!
      r.begin_eligibility_review!
      r if target == :eligibility_review
    end

    def swap_adapter(update_referral:)
      mock = Object.new
      mock.define_singleton_method(:update_referral, &update_referral)
      Corvid.configure { |c| c.adapter = mock }
    end
  end
end
