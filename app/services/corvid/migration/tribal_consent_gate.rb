# frozen_string_literal: true

module Corvid
  module Migration
    # The sovereignty checkpoint. Deny => no transfer. Non-negotiable.
    class TribalConsentGate
      Decision = Data.define(:granted, :consented_types, :reason) do
        def granted? = granted
      end
      def evaluate(case_record:, consent:)
        return Decision.new(granted: false, consented_types: [], reason: "Data Governance Board consent not granted") unless consent&.granted?
        return Decision.new(granted: false, consented_types: [], reason: "No resource types consented for release") if Array(consent.consented_resource_types).empty?
        Decision.new(granted: true, consented_types: consent.consented_resource_types, reason: nil)
      end
    end
  end
end
