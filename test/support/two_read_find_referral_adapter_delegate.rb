# frozen_string_literal: true

# Wraps Corvid.adapter for tests where consecutive find_referral calls must
# return different EHR snapshots (issue #675 / PR #693).
class TwoReadFindReferralAdapterDelegate
  attr_reader :find_referral_calls

  def initialize(inner, referral_identifier:, first_read_overrides:)
    @inner = inner
    @referral_identifier = referral_identifier.to_s
    @first_read_overrides = first_read_overrides
    @find_referral_calls = 0
  end

  def reset!
    @inner.reset! if @inner.respond_to?(:reset!)
    @find_referral_calls = 0
  end

  def find_referral(referral_identifier)
    ref = @inner.find_referral(referral_identifier)
    return ref unless ref && referral_identifier.to_s == @referral_identifier

    @find_referral_calls += 1
    return ref if @find_referral_calls > 1

    ref.with(**@first_read_overrides)
  end

  def respond_to_missing?(method, include_private = false)
    @inner.respond_to?(method, include_private) || super
  end

  def method_missing(method, *args, **kwargs, &block)
    @inner.public_send(method, *args, **kwargs, &block)
  end
end
