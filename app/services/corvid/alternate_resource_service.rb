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

      def all_exhausted?(prc_referral, date_of_service: Date.current, as_of: Time.current)
        Corvid::AlternateResourceCheck.all_exhausted?(
          prc_referral, date_of_service: date_of_service, as_of: as_of
        )
      end

      # Date omitted keeps the status scope so existing callers that have not
      # recorded checked_at still see enrollment. A date counts only coverage
      # that is current for that date of service.
      def has_active_coverage?(prc_referral, date_of_service: nil, as_of: Time.current)
        checks = prc_referral.alternate_resource_checks.active_coverage
        return checks.exists? if date_of_service.nil?

        checks.any? { |check| check.current_for?(date_of_service, as_of: as_of) }
      end
    end
  end
end
