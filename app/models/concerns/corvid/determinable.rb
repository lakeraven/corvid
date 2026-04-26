# frozen_string_literal: true

module Corvid
  # Mixin for models that can have determinations (Case, PrcReferral).
  # Determinations are individual decisions (approve/deny/defer) recorded
  # against a model. Each determination optionally references a practitioner
  # via determined_by_identifier (opaque external token).
  module Determinable
    extend ActiveSupport::Concern

    included do
      has_many :determinations, as: :determinable, dependent: :destroy, class_name: "Corvid::Determination"
    end

    def record_determination!(outcome:, decision_method: "automated", reasons: [], determination_data: {}, determined_by_identifier: nil, determined_at: nil, reasons_token: nil)
      # Auto-generate a reasons token for denied determinations if not provided
      token = reasons_token
      if token.nil? && outcome.to_s == "denied" && reasons.any?
        token = Corvid.adapter.store_text(case_token: id.to_s, kind: :reason, text: reasons.join("; "))
      elsif token.nil? && outcome.to_s == "denied"
        token = Corvid.adapter.store_text(case_token: id.to_s, kind: :reason, text: "Denied")
      end

      determinations.create!(
        tenant_identifier: tenant_identifier,
        facility_identifier: facility_identifier,
        outcome: outcome,
        decision_method: decision_method,
        determined_by_identifier: determined_by_identifier,
        determined_at: determined_at || Time.current,
        reasons_token: token
      )
    end

    def latest_determination
      determinations.order(determined_at: :desc).first
    end

    def has_approved_determination?
      determinations.where(outcome: "approved").exists?
    end

    def has_denied_determination?
      determinations.where(outcome: "denied").exists?
    end

    def determination_status
      latest_determination&.outcome || "undetermined"
    end

    def approve!(reasons: [], determined_by_identifier: nil, decision_method: "automated")
      record_determination!(outcome: "approved", decision_method: decision_method, reasons: reasons, determined_by_identifier: determined_by_identifier)
    end

    def deny!(reasons:, determined_by_identifier: nil, decision_method: "staff_review")
      record_determination!(outcome: "denied", decision_method: decision_method, reasons: reasons, determined_by_identifier: determined_by_identifier)
    end

    def defer!(reasons:, determined_by_identifier: nil, decision_method: "automated")
      record_determination!(outcome: "deferred", decision_method: decision_method, reasons: reasons, determined_by_identifier: determined_by_identifier)
    end
  end
end
