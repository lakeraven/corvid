# frozen_string_literal: true

module Corvid
  # One analysis pass over a PRC obligation. Multiple rows per obligation
  # over time as the analyzer / rate sources improve — this preserves
  # history so you can answer "what did we think this was worth in May
  # vs what we know now."
  class PrcOverpaymentAnalysis < ::ActiveRecord::Base
    self.table_name = "corvid_prc_overpayment_analyses"

    include TenantScoped

    monetize :medicare_equivalent_cents, with_model_currency: :currency_iso, allow_nil: true
    monetize :overpayment_cents, with_model_currency: :currency_iso, allow_nil: true

    belongs_to :prc_obligation, class_name: "Corvid::PrcObligation"

    validates :analyzer_version, presence: true
    validates :recovery_confidence, presence: true
    validates :analyzed_at, presence: true

    scope :clear, -> { where(recovery_confidence: "clear") }
    scope :stub_estimate, -> { where(recovery_confidence: "stub_estimate") }
    scope :pending_real_data,
          -> { where(recovery_confidence: %w[stub_estimate no_rate_for_year]) }
  end
end
