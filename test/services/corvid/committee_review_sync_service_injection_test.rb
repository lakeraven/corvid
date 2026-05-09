# frozen_string_literal: true

require "test_helper"

# Per #222 / ADR 0005: services accept an `adapter:` kwarg so per-tenant
# adapters and per-test fakes can be injected without mutating the
# global Corvid.adapter. The class method form preserves backward
# compatibility for existing callers.
class Corvid::CommitteeReviewSyncServiceInjectionTest < ActiveSupport::TestCase
  TENANT = "tnt_inject"

  # Minimal fake adapter that records every call it receives — lets us
  # assert that the service routed through the injected adapter rather
  # than the global Corvid.adapter.
  class RecordingAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def update_referral(identifier, params)
      @calls << [ :update_referral, identifier, params ]
      true
    end

    def fetch_text(token)
      @calls << [ :fetch_text, token ]
      "text-for-#{token}"
    end
  end

  setup do
    @fake = RecordingAdapter.new
  end

  test "instance.sync_decision routes through the injected adapter, not Corvid.adapter" do
    review = build_approved_review
    Corvid.configure { |c| c.adapter = poison_adapter } # blow up if global is used
    service = Corvid::CommitteeReviewSyncService.new(adapter: @fake)

    result = service.sync_decision(review)

    assert result[:success], "expected success but got #{result.inspect}"
    assert_includes @fake.calls.map(&:first), :update_referral,
                    "the fake adapter must have received update_referral; got #{@fake.calls.inspect}"
  end

  test "class .sync_decision accepts adapter: kwarg without touching the global" do
    review = build_approved_review
    Corvid.configure { |c| c.adapter = poison_adapter }

    result = Corvid::CommitteeReviewSyncService.sync_decision(review, adapter: @fake)

    assert result[:success]
    assert_includes @fake.calls.map(&:first), :update_referral
  end

  test "sync_and_apply! routes the SYNC half through the injected adapter" do
    # Half-pin: assert that the sync_decision portion of sync_and_apply!
    # uses the injected adapter. The apply portion goes through model
    # callbacks (PrcReferral AASM after-hooks → Corvid.adapter directly)
    # — that's the documented #264 gap. We don't poison the global here
    # because the apply half legitimately needs it until #264 lands.
    review = build_approved_review
    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
    service = Corvid::CommitteeReviewSyncService.new(adapter: @fake)

    service.sync_and_apply!(review)

    assert_includes @fake.calls.map(&:first), :update_referral,
                    "the injected adapter must receive the sync_decision call"
  end

  test "sync_and_apply! apply half currently routes through Corvid.adapter (gated on #264)" do
    # Boundary-pin: documents the limitation so when #264 lands and the
    # model callbacks become DI-aware, this test will fail and prompt
    # us to flip it into a stricter assertion ("apply half also routes
    # through @adapter"). Until then, this is the fact on the ground.
    review = build_approved_review
    global = Corvid::Adapters::MockAdapter.new
    spy_global = []
    global.define_singleton_method(:update_referral) do |id, params|
      spy_global << [ :update_referral, id, params ]
      true
    end
    Corvid.configure { |c| c.adapter = global }

    Corvid::CommitteeReviewSyncService.new(adapter: @fake).sync_and_apply!(review)

    # When the model layer is decoupled in #264, this assertion should
    # be inverted to `assert_empty spy_global` and the apply half should
    # also land in @fake.calls.
    assert spy_global.any?,
           "apply_to_referral! is expected to route through the global until #264; if this test now reports @fake received the call instead, tighten the assertion"
  end

  test "class .sync_decision still works with no kwarg, falling back to Corvid.adapter" do
    # Backward-compat path — existing callers that didn't know about DI
    # keep working. The global is the default, not the only option.
    review = build_approved_review
    Corvid.configure { |c| c.adapter = @fake }

    result = Corvid::CommitteeReviewSyncService.sync_decision(review)

    assert result[:success]
    assert_includes @fake.calls.map(&:first), :update_referral
  end

  private

  def build_approved_review
    Corvid::TenantContext.with_tenant(TENANT) do
      ref = Corvid::PrcReferral.create!(
        case: Corvid::Case.create!(
          patient_identifier: "p_inj", facility_identifier: "fac_inj"
        ),
        referral_identifier: "rf_inject_#{SecureRandom.hex(4)}",
        # Must be in committee_review for `authorize!` to fire its
        # after-callback; whiny_transitions=false would otherwise swallow
        # the transition silently and the model-callback path we're
        # trying to exercise would never run.
        status: "committee_review"
      )
      Corvid::CommitteeReview.create!(
        prc_referral: ref,
        committee_date: Date.current,
        decision: "approved",
        approved_amount_cents: 5_000_000,
        currency_iso: "USD",
        reviewer_identifier: "rv_inj"
      )
    end
  end

  def poison_adapter
    Object.new.tap do |o|
      def o.method_missing(name, *_a, **_kw)
        raise "Corvid.adapter (the global) was used unexpectedly: ##{name}"
      end

      def o.respond_to_missing?(_n, _p = false); true; end
    end
  end
end
