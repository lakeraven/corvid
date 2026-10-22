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

    def verify_eligibility(patient_identifier, resource_type)
      @calls << [ :verify_eligibility, patient_identifier, resource_type ]
      { eligible: false }
    end
  end

  setup do
    @fake = RecordingAdapter.new
    @original_adapter = Corvid.adapter
  end

  teardown do
    # Each test below mutates Corvid.adapter (to poison it or replace
    # it with a recording fake). test_helper.rb's setup re-resets the
    # adapter for the next test, but explicit teardown here keeps this
    # file self-contained and survives test_helper reorganizations.
    Corvid.configure { |c| c.adapter = @original_adapter }
  end

  test "instance.sync_decision re-verifies stale checks through the injected adapter only" do
    review = build_approved_review_with_stale_medicaid
    Corvid.configure { |c| c.adapter = poison_adapter }
    service = Corvid::CommitteeReviewSyncService.new(adapter: @fake)

    service.sync_decision(review)

    verify_calls = @fake.calls.select { |entry| entry.first == :verify_eligibility }
    assert verify_calls.any?,
           "stale alternate-resource checks must re-verify via the injected adapter; got #{@fake.calls.inspect}"
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
    exhaust_alternate_resources!(review.prc_referral)
    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
    service = Corvid::CommitteeReviewSyncService.new(adapter: @fake)

    service.sync_and_apply!(review)

    assert_includes @fake.calls.map(&:first), :update_referral,
                    "the injected adapter must receive the sync_decision call"
  end

  test "sync_and_apply! routes every verify_eligibility through injected adapter including apply_to_referral!" do
    travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
      review = build_approved_review
      medicaid = review.prc_referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
      medicaid.update!(checked_at: 31.days.ago)
      exhaust_alternate_resources!(review.prc_referral)
      global_verify_calls = []
      global = Corvid::Adapters::MockAdapter.new
      global.define_singleton_method(:verify_eligibility) do |patient_identifier, resource_type|
        global_verify_calls << [ patient_identifier, resource_type ]
        { eligible: false }
      end
      Corvid.configure { |c| c.adapter = global }
      service = Corvid::CommitteeReviewSyncService.new(adapter: @fake)

      service.sync_and_apply!(review)

      verify_calls = @fake.calls.select { |entry| entry.first == :verify_eligibility }
      assert verify_calls.any?,
             "stale checks re-verified during apply and sync must use the injected adapter; got #{@fake.calls.inspect}"
      assert_empty global_verify_calls,
                   "re-verification must not fall back to Corvid.adapter when an adapter is injected"
    end
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

  def build_approved_review_with_stale_medicaid
    travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
      review = build_approved_review
      medicaid = review.prc_referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
      medicaid.update!(checked_at: 31.days.ago)
      review
    end
  end

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
      exhaust_alternate_resources!(ref)
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
