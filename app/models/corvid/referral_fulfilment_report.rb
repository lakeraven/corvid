# frozen_string_literal: true

module Corvid
  # corvid#595: one external report of whether a PRC referral's care was
  # actually delivered. Append-only — a referral's current fulfilment
  # status (Corvid::ReferralFulfilment.status) is derived as "most recent
  # report wins", never cached on the referral itself. Rows here are
  # written only by Corvid::ReferralFulfilment.record_external_report!;
  # nothing in the claim/billing path writes to this table (a claim
  # arriving is never proof that care happened — that inversion is the
  # defect #595 exists to close).
  class ReferralFulfilmentReport < ::ActiveRecord::Base
    self.table_name = "corvid_referral_fulfilment_reports"

    include TenantScoped

    # Who/what is reporting. "receiving_specialist" is the clinician/site
    # that actually delivered (or didn't) the care; "patient" is the
    # beneficiary confirming or denying the appointment happened;
    # "staff" / "other" cover PRC staff relaying an external report they
    # received by phone/fax/portal rather than inferring one themselves.
    SOURCES = %w[receiving_specialist patient staff other].freeze

    # Exactly the two outcomes fulfilment can resolve to. There is no
    # "pending"/"scheduled" outcome here — absence of a report is
    # represented by absence of a row (see Corvid::ReferralFulfilment.status
    # returning "awaiting_report"), not by a row with a placeholder value.
    OUTCOMES = %w[delivered not_delivered].freeze

    belongs_to :prc_referral, class_name: "Corvid::PrcReferral"

    validates :source, inclusion: { in: SOURCES }
    validates :outcome, inclusion: { in: OUTCOMES }
    validates :reported_at, presence: true

    scope :chronological, -> { order(reported_at: :asc) }
    scope :reverse_chronological, -> { order(reported_at: :desc) }
    scope :delivered, -> { where(outcome: "delivered") }
    scope :not_delivered, -> { where(outcome: "not_delivered") }

    def delivered?
      outcome == "delivered"
    end

    def not_delivered?
      outcome == "not_delivered"
    end

    # The free-text circumstance as reported (e.g. "No-show cited"),
    # dereferenced through the adapter. May contain PHI-adjacent detail,
    # so it is stored as a vault token (detail_token), not a raw column —
    # same pattern as PrcReferral's reason/rationale tokens.
    def detail
      return nil if detail_token.blank?

      Corvid.adapter.fetch_text(detail_token)
    end
  end
end
