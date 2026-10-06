# frozen_string_literal: true

module Corvid
  # corvid#595: fulfilment facts — did the referred care actually happen —
  # originate OUTSIDE this engine (the receiving specialist, or the
  # patient confirming the appointment). This service is the only writer
  # of Corvid::ReferralFulfilmentReport rows, and the only thing that may
  # answer "is this referral billable for delivered care". Nothing here
  # ever infers, synthesizes, or defaults a fulfilment fact: no report
  # means "awaiting_report", full stop, not "assume delivered" and not
  # "assume not delivered".
  #
  # Per ADR 0005, adapter access would normally be injected; this service
  # only reaches the adapter for the vault token round-trip (store_text /
  # fetch_text), which — like PrcReferral's reason/rationale tokens —
  # uses the Corvid.adapter global directly rather than per-instance
  # injection, since there's no per-call adapter swap requirement here.
  class ReferralFulfilment
    class << self
      # Record one external report. Each call appends a row; it never
      # overwrites or merges with a prior report — the full reporting
      # history stays auditable, and #status always reflects whichever
      # report is most recent by reported_at.
      def record_external_report!(referral, source:, outcome:, reported_at:, detail: nil)
        Corvid::ReferralFulfilmentReport.create!(
          tenant_identifier: referral.tenant_identifier,
          facility_identifier: referral.facility_identifier,
          prc_referral: referral,
          source: source,
          outcome: outcome,
          reported_at: reported_at,
          detail_token: store_detail(referral, detail)
        )
      end

      # Discards all reports for a referral. Used by specs to set up "no
      # external fulfilment report has been received" — a real caller
      # would have no legitimate reason to erase reporting history, but
      # the method is intentionally here (not open-coded in a step
      # definition) so it's one obvious place, not scattered deletes.
      def clear_reports!(referral)
        referral.fulfilment_reports.destroy_all
      end

      def latest_report(referral)
        referral.fulfilment_reports.reverse_chronological.first
      end

      # "awaiting_report" — not "pending", "scheduled", or any inferred
      # in-between — is the only status a referral has until an external
      # report names one of the two real outcomes.
      def status(referral)
        latest_report(referral)&.outcome || "awaiting_report"
      end

      def billable_for_delivered_care?(referral)
        status(referral) == "delivered"
      end

      # Structural guarantee, not a computed check: a claim's existence,
      # status, or payer response is never read by #status or anywhere
      # else in this class. This method exists so the inversion #595
      # closes has an explicit assertion point instead of being "true by
      # the absence of code that would do it".
      def inferred_from_claim?(_referral, _claim_submission)
        false
      end

      # Normalized reason tokens for every not_delivered report, derived
      # from the reported detail text (e.g. "No-show cited" ->
      # "no_show_cited"). This is normalization of what was explicitly
      # reported, not inference of a new fact — the raw text stays
      # available via ReferralFulfilmentReport#detail.
      def not_delivered_reasons(referral)
        referral.fulfilment_reports.not_delivered.chronological.filter_map do |report|
          slugify(report.detail)
        end
      end

      private

      def store_detail(referral, detail)
        return nil if detail.blank?

        Corvid.adapter.store_text(
          case_token: referral.case&.id&.to_s || "unknown",
          kind: :fulfilment_detail,
          text: detail
        )
      end

      def slugify(text)
        return nil if text.blank?

        text.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "").presence
      end
    end
  end
end
