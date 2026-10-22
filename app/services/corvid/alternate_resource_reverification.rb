# frozen_string_literal: true

module Corvid
  # Re-confirms alternate-resource checks that are not current for a date of
  # service, and records which answers an authorization or claim relied on.
  # An unreadable lookup is not a determination (42 CFR 136.61). Identifiers
  # only — no patient, payer, or policy data (ADR 0003).
  class AlternateResourceReverification
    class << self
      # adapter defaults to Corvid.adapter for model callers. A service
      # that holds an injected adapter passes it (ADR 0005).
      def reverify_stale!(prc_referral, date_of_service:, as_of: Time.current, adapter: Corvid.adapter)
        stale_checks(prc_referral, date_of_service, as_of).map { |check|
          confirm_check(check, date_of_service, as_of, adapter: adapter)
        }.all?
      end

      def record!(target, activity:, checks:)
        payload = provenance_payload(target, activity, checks)
        Corvid.configuration.on_provenance&.call(**payload)
      rescue StandardError => e
        Rails.logger.error("Provenance hook failed: #{Corvid.sanitize_phi(e.message)}")
      end

      private

      def stale_checks(prc_referral, date_of_service, as_of)
        prc_referral.alternate_resource_checks.reload.select do |check|
          needs_reverification?(check, date_of_service, as_of)
        end
      end

      # current_for? is the only freshness test: the configured per-type
      # max age and the coverage period. There is no shared 30-day window.
      def needs_reverification?(check, date_of_service, as_of)
        !check.current_for?(date_of_service, as_of: as_of)
      end

      def confirm_check(check, date_of_service, as_of, adapter:)
        return false unless check.verify!(adapter: adapter)

        check.reload
        check.current_for?(date_of_service, as_of: as_of_after_verify(check, as_of))
      rescue StandardError, NotImplementedError
        false
      end

      # verify! stamps checked_at with Time.current, which can be a few
      # milliseconds after the as_of captured when re-verification started.
      # That answer is this decision, not a future one.
      def as_of_after_verify(check, as_of)
        stamped = check.checked_at
        return as_of if stamped.nil? || stamped <= as_of
        return stamped if stamped <= Time.current

        as_of
      end

      def provenance_payload(target, activity, checks)
        {
          target_type: target.class.name,
          target_id: target.id.to_s,
          activity: activity,
          recorded: Time.current,
          entities: Array(checks).map { |check| provenance_entity(check) }
        }
      end

      def provenance_entity(check)
        {
          id: check.id,
          resource_type: check.resource_type,
          status: check.status,
          checked_at: check.checked_at,
          coverage_start: check.coverage_start,
          coverage_end: check.coverage_end,
          renewal_date: check.renewal_date
        }
      end
    end
  end
end
