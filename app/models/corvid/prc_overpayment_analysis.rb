# frozen_string_literal: true

module Corvid
  # One analysis pass over a PRC obligation. Multiple rows per obligation
  # over time as the analyzer / rate sources improve — this preserves
  # history so you can answer "what did we think this was worth in May
  # vs what we know now."
  class PrcOverpaymentAnalysis < ::ActiveRecord::Base
    self.table_name = "corvid_prc_overpayment_analyses"

    include TenantScoped
    include CurrencyImmutable

    monetize :medicare_equivalent_cents, with_model_currency: :currency_iso, allow_nil: true
    monetize :overpayment_cents, with_model_currency: :currency_iso, allow_nil: true

    belongs_to :prc_obligation, class_name: "Corvid::PrcObligation"

    # PrcOverpaymentAnalyzer payment systems. Null when the obligation is unmapped.
    # Same set as corvid_prc_overpayment_analyses_payment_system_check (ADR 0002).
    PAYMENT_SYSTEMS = %w[pfs ipps asc opps].freeze
    # PrcOverpaymentAnalyzer recovery confidence levels.
    # Same set as corvid_prc_overpayment_analyses_recovery_confidence_check.
    RECOVERY_CONFIDENCES = %w[
      clear stub_estimate no_rate_for_year unmapped_procedure unmapped_facility missing_service_date
    ].freeze

    validates :analyzer_version, presence: true
    validates :payment_system, inclusion: { in: PAYMENT_SYSTEMS }, allow_nil: true
    validates :recovery_confidence, presence: true, inclusion: { in: RECOVERY_CONFIDENCES }
    validates :analyzed_at, presence: true

    scope :clear, -> { where(recovery_confidence: "clear") }
    scope :stub_estimate, -> { where(recovery_confidence: "stub_estimate") }
    scope :pending_real_data,
          -> { where(recovery_confidence: %w[stub_estimate no_rate_for_year]) }

    # Recoverable-now: priced from real CMS rate data with clear confidence.
    # Single source of truth lives in Corvid::RecoverableRule — council-
    # facing CSV/PDF reports gate dollar totals on this predicate. The
    # scope uses the same set (IN clause) so model-level filtering can't
    # diverge from the predicate when new "real" labels are whitelisted.
    scope :recoverable, -> { clear.where(rate_source: Corvid::RecoverableRule::RECOVERABLE_RATE_SOURCES) }
    scope :exceptions, -> { where.not(id: recoverable) }

    def recoverable?
      Corvid::RecoverableRule.recoverable?(self)
    end
  end
end
