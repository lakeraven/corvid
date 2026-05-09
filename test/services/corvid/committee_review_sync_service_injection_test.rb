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
        status: "submitted"
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
