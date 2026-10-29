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
      # date_of_service is the date being judged. It is forwarded to
      # verify! unchanged. A non-Date raises ArgumentError there and is
      # not coerced.
      def reverify_stale!(prc_referral, date_of_service:, as_of: Time.current, adapter: Corvid.adapter)
        stale_checks(prc_referral, date_of_service, as_of).map { |check|
          confirm_check(check, date_of_service, as_of, adapter: adapter)
        }.all?
      end

      # entities is the decision-time snapshot. tenant is the TenantContext
      # captured with that decision; delivery runs inside it (ADR 0002).
      def record!(target, activity:, entities:, tenant:)
        hook = Corvid.configuration.on_provenance
        return unless hook

        deliver_provenance_hook(target, hook, provenance_payload(target, activity, entities), tenant)
      rescue StandardError => e
        Rails.logger.error("Provenance hook failed: #{Corvid.sanitize_phi(e.message)}")
      end

      # Plain hashes copied at decision time. Delivery must not reload the
      # checks: a later write in the same host transaction is not this decision.
      def snapshot_entities(checks)
        Array(checks).map { |check| provenance_entity(check) }
      end

      private

      # A hook that runs SQL shares the caller's transaction. Keep it in
      # its own savepoint so a database error cannot abort that transaction
      # or undo a decision that already committed.
      def deliver_provenance_hook(target, hook, payload, tenant)
        Corvid::TenantContext.with_tenant(tenant) do
          target.class.transaction(requires_new: true) do
            hook.call(**payload)
          end
        end
      end

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

      # One savepoint per check. A host adapter that raises a database
      # error must not leave the caller's transaction aborted; this check
      # stays unconfirmed and the transition is refused. The judged date
      # is passed through to verify!.
      def confirm_check(check, date_of_service, as_of, adapter:)
        verified = check.class.transaction(requires_new: true) do
          check.verify!(date_of_service: date_of_service, adapter: adapter)
        end
        return false unless verified

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

      def provenance_payload(target, activity, entities)
        {
          target_type: target.class.name,
          target_id: target.id.to_s,
          activity: activity,
          recorded: Time.current,
          entities: entities
        }
      end

      def provenance_entity(check)
        {
          id: check.id,
          resource_type: detach(check.resource_type),
          status: detach(check.status),
          checked_at: detach(check.checked_at),
          coverage_start: detach(check.coverage_start),
          coverage_end: detach(check.coverage_end),
          renewal_date: detach(check.renewal_date)
        }
      end

      def detach(value)
        value.duplicable? ? value.dup : value
      end
    end
  end
end
