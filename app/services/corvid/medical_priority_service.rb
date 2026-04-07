# frozen_string_literal: true

module Corvid
  # Assigns medical priority to a PRC referral based on EHR clinical data.
  class MedicalPriorityService
    PRIORITIES = { emergent: 1, urgent: 2, routine: 3 }.freeze

    class << self
      def assign(prc_referral)
        sr = prc_referral.service_request
        return :unknown unless sr

        priority = compute_priority(sr)
        prc_referral.update!(medical_priority: priority, priority_system: "corvid_v1")
        priority
      end

      private

      def compute_priority(sr)
        return PRIORITIES[:emergent] if sr.emergent?
        return PRIORITIES[:urgent] if sr.urgent?

        sr.medical_priority_level || PRIORITIES[:routine]
      end
    end
  end
end
