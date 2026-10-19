# frozen_string_literal: true

module Corvid
  # Raised when an approval would authorize a referral that cannot be
  # authorized: alternate resources are not determined, or the referral
  # is in a state that will not authorize (42 CFR 136.61). `blockers`
  # and the message name resource type and status, or that state —
  # never patient, payer, or policy data (ADR 0003).
  class AuthorizationBlockedError < StandardError
    attr_reader :blockers

    def initialize(blockers)
      @blockers = Array(blockers).map(&:to_s)
      super("Authorization blocked: #{@blockers.join('; ')}")
    end
  end
end
