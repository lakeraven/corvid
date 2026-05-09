# frozen_string_literal: true

module Corvid
  module OverpaymentRecovery
    # Pure date math for the recovery timeline:
    # - 60-day return deadline (tribal/Section 506)
    # - Interest begins accruing after 30 days of non-payment
    # - Follow-up cadence: 30-day courtesy reminder, 60-day FCA warning,
    #   90-day escalation
    module Timeline
      DEFAULT_TRIBAL_DEADLINE = 60
      INTEREST_GRACE_DAYS = 30
      COURTESY_REMINDER_DAYS = 30
      FCA_WARNING_DAYS = 60
      ESCALATION_DAYS = 90

      # Treasury rate fallback. The real implementation would pull this
      # from a current-rates table updated quarterly; for now we expose
      # a constant so callers can identify the source on the report.
      TREASURY_RATE_LABEL = "current Treasury rate"
      TREASURY_RATE = BigDecimal("0.05") # placeholder annual rate

      def self.return_deadline(sent_on:, deadline_days: DEFAULT_TRIBAL_DEADLINE)
        sent_on + deadline_days
      end

      def self.interest_accrual_starts(sent_on:)
        sent_on + INTEREST_GRACE_DAYS
      end

      def self.interest_owed(amount:, sent_on:, today:)
        elapsed = (today - sent_on).to_i
        return BigDecimal("0") if elapsed <= INTEREST_GRACE_DAYS

        accrual_days = elapsed - INTEREST_GRACE_DAYS
        principal = BigDecimal(amount.to_s)
        (principal * TREASURY_RATE * accrual_days / 365).round(2)
      end

      def self.days_with_accrued_interest(sent_on:, today:)
        elapsed = (today - sent_on).to_i
        [ elapsed - INTEREST_GRACE_DAYS, 0 ].max
      end

      # Returns one of: nil, :courtesy_reminder, :fca_warning,
      # :final_notice, :escalation — used by the follow-up service to
      # decide what kind of letter to generate for a demand that hasn't
      # been paid yet.
      #
      # `cites_section_506` scopes the 60-day branch: only Section 506
      # tribal demands escalate to :fca_warning (FCA / treble damages
      # citation). Contractual / rural demands at 60 days fall back to
      # :final_notice (firmer language without the FCA threat) since
      # invoking the False Claims Act outside its statutory basis would
      # be a legal/compliance risk.
      def self.follow_up_kind(sent_on:, today:, cites_section_506: true)
        elapsed = (today - sent_on).to_i
        if elapsed >= ESCALATION_DAYS
          :escalation
        elsif elapsed >= FCA_WARNING_DAYS
          cites_section_506 ? :fca_warning : :final_notice
        elsif elapsed >= COURTESY_REMINDER_DAYS
          :courtesy_reminder
        end
      end
    end
  end
end
