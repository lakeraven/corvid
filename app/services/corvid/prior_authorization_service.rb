# frozen_string_literal: true

module Corvid
  # Determines whether a PRC referral requires prior authorization based
  # on cost thresholds, priority, and committee flags.
  class PriorAuthorizationService
    class << self
      def required?(prc_referral)
        prc_referral.requires_committee?
      end

      def auto_authorizable?(prc_referral)
        !required?(prc_referral) && Corvid::AlternateResourceService.all_exhausted?(prc_referral)
      end
    end
  end
end
