# frozen_string_literal: true

module Corvid
  # Drives alternate resource verification for a PRC referral.
  # Each of the 12 RESOURCE_TYPES is checked via the adapter.
  class AlternateResourceService
    class << self
      def verify_all(prc_referral)
        Corvid::AlternateResourceCheck.create_all_for_referral(prc_referral)
        Corvid::AlternateResourceCheck.verify_all_for_referral(prc_referral)
      end

      def all_exhausted?(prc_referral)
        Corvid::AlternateResourceCheck.all_exhausted?(prc_referral)
      end

      def has_active_coverage?(prc_referral)
        prc_referral.alternate_resource_checks.active_coverage.exists?
      end
    end
  end
end
